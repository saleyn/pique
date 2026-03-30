defmodule Pique.Smtp do
  require Logger
  @behaviour :gen_smtp_server_session

  @doc """
  Init callback for new SMTP sessions. Checks if the new initiated session
  exceeds the allowed session count. If it does, responds with an error.
  Otherwise returns the expected banner message.
  """
  @spec init(any, any, any, any) :: {:ok, [...], %{}} | {:stop, :normal, [...]}
  def init(hostname, session_count, _address, _options) do
    if session_count > Application.get_env(:pique, :session_limit, 40) do
      Logger.warning("SMTP server connection limit #{session_count} exceeded")
      {:stop, :normal, ["421", hostname, " is too busy to accept mail right now"]}
    else
      banner = [hostname, " ESMTP"]
      state = %{
        auth_enabled: Application.get_env(:pique, :auth, false),
        data_handler: Application.get_env(:pique, :data_handler, Pique.Handlers.DATA),
        sender: Application.get_env(:pique, :sender, Pique.Senders.Logger),
        mail_handler: Application.get_env(:pique, :mail_handler, Pique.Handlers.MAIL),
        rcpt_handler: Application.get_env(:pique, :rcpt_handler, Pique.Handlers.RCPT),
        auth_handler: Application.get_env(:pique, :auth_handler, Pique.Handlers.AUTH)
      }
      {:ok, banner, state}
    end
  end

  @doc """
  Handles incoming DATA request. Matches if the message is empty and
  returns an error.
  """
  @spec handle_DATA(any, any, String.t|any, map) :: {:ok, String.t, any} | {:error, iolist(), map}
  def handle_DATA(_from, _to, "", state) do
    {:error, ~c"552 Message too small", state}
  end

  def handle_DATA(_from, _to, data, state) do
    Logger.debug("Received DATA")
    state = Map.put(state, :body, data)
    with {:ok, state} <- state.data_handler.handle(state),
         {:ok, response, updated_state} <- state.sender.send(state) do
      {:ok, response, updated_state}
    else
      {:error, msg} ->
        {:error, append(~c"552 ", msg), state}
      {:error, msg, state} ->
        {:error, append(~c"552 ", msg), state}
    end
  end

  @doc """
  Handles incoming EHLO request and returns a list of extensions.
  If the `auth` config is set to true, it automatically adds in
  `AUTH` and `STARTTLS` extensions.
  """
  @spec handle_EHLO(any, any, map) :: {:ok, [any], map}
  def handle_EHLO(hostname, extensions, state) do
    Logger.debug("EHLO from #{hostname}")
    auth_extensions = if state.auth_enabled, do: [{~c"AUTH", ~c"PLAIN LOGIN"}, {~c"STARTTLS", true}], else: []
    {:ok, extensions ++ auth_extensions, state}
  end

  @doc """
  Handles incoming HELO request and returns a limit of 640Kb.
  """
  @spec handle_HELO(any, map) :: {:ok, 655_360, map}
  def handle_HELO(hostname, state) do
    Logger.debug("HELO from #{hostname}")
    {:ok, 655_360, state}
  end

  @doc """
  Handles incoming MAIL request and passes the from address to
  the defined MAIL handler. If the handler passes then adds the
  from address to the state.
  """
  @spec handle_MAIL(any, map) :: {:ok, %{from: map}} | {:error, charlist(), map}
  def handle_MAIL(from, state) do
    Logger.debug("MAIL from #{from}")
    case state.mail_handler.handle(from) do
      {:ok, from} ->
        {:ok, Map.put(state, :from, from)}
      {:error, msg} ->
        {:error, append(~c"550 ", msg), state}
    end
  end

  @doc """
  Handles MAIL extension requests. Does nothing.
  """
  @spec handle_MAIL_extension(any, map) :: {:ok, map}
  def handle_MAIL_extension(extension, state) do
    Logger.debug(extension)
    {:ok, state}
  end

  @doc """
  Handles incoming EHLO request and returns a list of extensions.
  If the `auth` config is set to true, it automatically adds in
  `AUTH` and `STARTTLS` extensions.
  """
  @spec handle_RCPT(any, map) ::
          {:ok, %{rcpt: nonempty_maybe_improper_list}} | {:error, charlist(), map}
  def handle_RCPT(to, state) do
    Logger.debug("RCPT to #{to}")
    case state.rcpt_handler.handle(to) do
      {:ok, to} ->
        {:ok, Map.put(state, :rcpt, [to | Map.get(state, :rcpt, [])])}
      {:error, msg} ->
        {:error, append(~c"550 ", msg), state}
    end
  end

  @doc """
  Handles RCPT extension requests. Does nothing.
  """
  @spec handle_RCPT_extension(any, map) :: {:ok, map}
  def handle_RCPT_extension(extension, state) do
    Logger.debug(extension)
    {:ok, state}
  end

  @doc """
  Handles STARTTLS request by indicating TLS is not supported.
  """
  @spec handle_STARTTLS(map) :: {:error, charlist(), map} | {:ok, map}
  def handle_STARTTLS(state) do
    {:error, ~c"454 TLS not available", state}
  end

  @doc """
  Handles RSET requests by removing the existing envelope
  information from the state.
  """
  @spec handle_RSET(map) :: {:ok, map}
  def handle_RSET(state) do
    state =
      state
      |> Map.delete(:rcpt)
      |> Map.delete(:from)
      |> Map.delete(:body)

    {:ok, state}
  end

  @doc """
  Handles VRFY requests by telling people to go away.
  """
  @spec handle_VRFY(any, any) ::
          {:error, [32 | 50 | 53 | 78 | 101 | 111 | 114 | 115 | 116 | 117, ...], any}
  def handle_VRFY(address, state) do
    Logger.debug("VRFY for #{address}")
    {:error, ~c"252 Not sure", state}
  end

  @doc """
  Handles incoming AUTH request and passes it off to the defined AUTH
  handler. If the AUTH handler returns an `{:ok, state}`. Otherwise
  returns relevant error messages.
  """
  @spec handle_AUTH(any, any, any, any) :: {:ok, any} | {:error, iodata(), any}
  def handle_AUTH(type, username, password, state) when type == :login or type == :plain do
    Logger.debug("AUTH request")
    case state.auth_handler.handle({username, password}) do
      {:ok, _} ->
        {:ok, state}
      {:error, msg} ->
        {:error, append(~c"530 ", msg), state}
    end
  end

  # Handles incoming AUTH request that do not use the PLAIN or
  # LOGIN type - looking at you CRAM-MD5. Telling client to use
  # PLAIN or LOGIN.
  def handle_AUTH(_type, _username, _password, state) do
    {:error, ~c"530 Use PLAIN or LOGIN", state}
  end

  @doc """
  Handles incoming unkown request. Telling client that
  it does not understand.
  """
  @spec handle_other(any, any, any) :: {charlist(), any}
  def handle_other(command, _args, state) do
    Logger.debug(command)
    {~c"500 Error: command not recognized : #{command}", state}
  end

  @doc """
  Handles hot swap code change (in theory). Does nothing in
  practice.
  """
  @spec code_change(any, any, any) :: {:ok, any}
  def code_change(_old, state, _extra) do
    {:ok, state}
  end

  @doc """
  Handles session termination. Does nothing.
  """
  @spec terminate(String.t, map) :: {:ok, any, map}
  def terminate(reason, state) do
    Logger.debug("Terminating Session: #{reason}")
    {:ok, reason, state}
  end

  defp append(prefix, msg) when is_list(msg), do: prefix ++ msg
  defp append(prefix, msg) when is_binary(msg), do: prefix ++ String.to_charlist(msg)
end
