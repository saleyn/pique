defmodule SmtpTest do
  use ExUnit.Case

  alias Pique.Smtp

  describe "init/4" do
    test "intializes state and generates a banner if there are enough sessions" do
      {:ok, banner, state} = Smtp.init("foo", 40, nil, nil)
      assert banner == ["foo", " ESMTP"]
      assert Map.has_key?(state, :data_handler)
      assert Map.has_key?(state, :sender)
      assert Map.has_key?(state, :mail_handler)
      assert Map.has_key?(state, :rcpt_handler)
      assert Map.has_key?(state, :auth_handler)
      assert Map.has_key?(state, :auth_enabled)
    end

    test "returns an error is the server connection limit is exceeded" do
      assert Smtp.init("foo", 41, nil, nil) == {
        :stop,
        :normal,
        ["421", "foo", " is too busy to accept mail right now"]
      }
    end

    test "allows you to cusomtize the limit" do
      Application.put_env(:pique, :session_limit, 20)
      assert Smtp.init("foo", 21, nil, nil) == {
        :stop,
        :normal,
        ["421", "foo", " is too busy to accept mail right now"]
      }
      Application.delete_env(:pique, :session_limit)
    end
  end

  describe "handle_DATA/4" do
    test "returns an error is the message is empty" do
      assert Smtp.handle_DATA("foo", "bar", "", :state) == {
        :error,
        ~c"552 Message too small",
        :state
      }
    end

    test "returns an error is the DATA handler fails" do
      state = %{
        data_handler: Pique.TestHandlers.DataFail,
        sender: Pique.TestSenders.TestPass
      }
      assert Smtp.handle_DATA("foo", "bar", "foo", state) == {
        :error,
        ~c"552 Failed to pass DATA handler",
        %{body: "foo", data_handler: Pique.TestHandlers.DataFail, sender: Pique.TestSenders.TestPass}
      }
    end

    test "returns an error is the sender fails" do
      state = %{
        data_handler: Pique.TestHandlers.DataPass,
        sender: Pique.TestSenders.TestFail
      }
      assert Smtp.handle_DATA("foo", "bar", "foo", state) == {
        :error,
        ~c"552 Failed to pass Sender",
        %{body: "foo", data_handler: Pique.TestHandlers.DataPass, sender: Pique.TestSenders.TestFail}
      }
    end

    test "returns an :ok if both handler and sender pass" do
      state = %{
        data_handler: Pique.TestHandlers.DataPass,
        sender: Pique.TestSenders.TestPass
      }
      assert Smtp.handle_DATA("foo", "bar", "foo", state) == {
        :ok,
        "foo",
        %{body: "foo", data_handler: Pique.TestHandlers.DataPass, sender: Pique.TestSenders.TestPass}
      }
    end
  end

  describe "handle_EHLO" do
    test "it returns all the non auth extensions by default" do
      state = %{auth_enabled: false}
      assert Smtp.handle_EHLO("foo", [{~c"FOO", ~c"BAR"}], state) == {
        :ok,
        [{~c"FOO", ~c"BAR"}],
        state
      }
    end

    test "it add auth extensions if auth config is set to true" do
      state = %{auth_enabled: true}
      assert Smtp.handle_EHLO("foo", [{~c"FOO", ~c"BAR"}], state) == {
        :ok,
        [{~c"FOO", ~c"BAR"}, {~c"AUTH", ~c"PLAIN LOGIN"}, {~c"STARTTLS", true}],
        state
      }
    end
  end

  describe "handle_HELO/2" do
    test "it returns a respose with 640Kb of HELO" do
      assert Smtp.handle_HELO("foo", :state) == {
        :ok,
        655360,
        :state
      }
    end
  end

  describe "handle_MAIL/2" do
    test "returns an error is the MAIL handler fails" do
      state = %{mail_handler: Pique.TestHandlers.MailFail}
      assert Smtp.handle_MAIL("foo", state) == {
        :error,
        ~c"550 Failed to pass MAIL handler",
        state
      }
    end

    test "adds from to the state if MAIL handler passes" do
      state = %{mail_handler: Pique.TestHandlers.MailPass}
      assert Smtp.handle_MAIL("foo", state) == {
        :ok,
        %{mail_handler: Pique.TestHandlers.MailPass, from: "foo"}
      }
    end
  end

  describe "handle_MAIL_extension/2" do
    test "does not change the state" do
      assert Smtp.handle_MAIL_extension([], :state) == {:ok, :state}
    end
  end

  describe "handle_RCPT/2" do
    test "returns an error is the RCPT handler fails" do
      state = %{rcpt_handler: Pique.TestHandlers.RcptFail}
      assert Smtp.handle_RCPT("foo", state) == {
        :error,
        ~c"550 Failed to pass RCPT handler",
        state
      }
    end

    test "adds receiver to the state if RCPT handler passes" do
      state = %{rcpt_handler: Pique.TestHandlers.RcptPass}
      assert Smtp.handle_RCPT("foo", state) == {
        :ok,
        %{rcpt_handler: Pique.TestHandlers.RcptPass, rcpt: ["foo"]}
      }
    end

    test "adds receiver to the state if RCPT handler passes and there are other recievers" do
      state = %{rcpt_handler: Pique.TestHandlers.RcptPass, rcpt: ["foo"]}
      assert Smtp.handle_RCPT("bar", state) == {
        :ok,
        %{rcpt_handler: Pique.TestHandlers.RcptPass, rcpt: ["bar", "foo"]}
      }
    end
  end

  describe "handle_RCPT_extension/2" do
    test "does not change the state" do
      assert Smtp.handle_RCPT_extension([], :state) == {:ok, :state}
    end
  end

  describe "handle_RSET/1" do
    test "removes envelope data from the state" do
      envelope = %{
        body: "foo",
        from: "bar",
        rcpt: ["baz"],
        other: "quix"
      }
      assert Smtp.handle_RSET(envelope) == {:ok, %{other: "quix"}}
    end
  end

  describe "handle_VRFY/2" do
    test "returns an error" do
      assert Smtp.handle_VRFY("foo", :state) == {
        :error,
        ~c"252 Not sure",
        :state}
    end
  end

  describe "handle_AUTH/4" do
    test "returns an error if type is not :login or :plain" do
      state = %{auth_handler: Pique.TestHandlers.AuthPass}
      assert Smtp.handle_AUTH(:foo, "foo", "bar", state) == {
        :error,
        ~c"530 Use PLAIN or LOGIN",
        state}
    end

    test "returns an error if it fails the auth handler" do
      state = %{auth_handler: Pique.TestHandlers.AuthFail}
      assert Smtp.handle_AUTH(:login, "foo", "bar", state) == {
        :error,
        ~c"530 Failed to pass AUTH handler",
        state}
    end

    test "returns state if it passes the auth handler" do
      state = %{auth_handler: Pique.TestHandlers.AuthPass}
      assert Smtp.handle_AUTH(:login, "foo", "bar", state) == {
        :ok,
        state}
    end
  end

  describe "handle_other/3" do
    test "returns an error" do
      assert Smtp.handle_other("foo", [], :state) == {
        ~c"500 Error: command not recognized : foo",
        :state}
    end
  end

  describe "code_change/3" do
    test "does not change the state" do
      assert Smtp.code_change(:foo, :state, :bar) == {:ok, :state}
    end
  end

  describe "terminate/2" do
    test "does not change the state" do
      assert Smtp.terminate(:foo, :state) == {:ok, :foo, :state}
    end
  end

end
