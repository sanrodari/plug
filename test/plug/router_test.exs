defmodule Plug.RouterTest do
  defmodule Forward do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :dispatch

    def call(conn, opts) do
      super(conn, opts)
    after
      Process.put(:plug_forward_call, true)
    end

    get "/" do
      conn |> resp(200, "forwarded")
    end

    get "/script_name" do
      conn |> resp(200, Enum.join(conn.script_name, ","))
    end

    match "/throw", via: [:get, :post] do
      _ = conn
      throw :oops
    end

    match "/raise" do
      _ = conn
      raise Plug.Parsers.RequestTooLargeError
    end

    match "/send_and_exit" do
      send_resp(conn, 200, "ok")
      exit(:oops)
    end

    def handle_errors(conn, assigns) do
      # Custom call is always invoked before
      true = Process.get(:plug_forward_call)

      Process.put(:plug_handle_errors, Map.put(assigns, :status, conn.status))
      super(conn, assigns)
    end
  end

  defmodule Reforward do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :dispatch

    forward "/step2", to: Forward
  end

  defmodule Sample do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :verify_router_options
    plug :dispatch

    get "/", host: "foo.bar", do: conn |> resp(200, "foo.bar root")
    get "/", host: "foo.",    do: conn |> resp(200, "foo.* root")
    forward "/", to: Forward, host: "foo."

    get "/" do
      conn |> resp(200, "root")
    end

    get "/1/bar" do
      conn |> resp(200, "ok")
    end

    get "/2/:bar" do
      conn |> resp(200, inspect(bar))
    end

    get "/3/bar-:bar" do
      conn |> resp(200, inspect(bar))
    end

    get "/4/*bar" do
      conn |> resp(200, inspect(bar))
    end

    get "/5/bar-*bar" do
      conn |> resp(200, inspect(bar))
    end

    match "/6/bar" do
      conn |> resp(200, "ok")
    end

    get "/7/:bar" when byte_size(bar) <= 3,
      some_option: :hello,
      do: conn |> resp(200, inspect(bar))

    get "/8/bar baz/:bat" do
      conn |> resp(200, bat)
    end

    forward "/step1", to: Reforward
    forward "/forward", to: Forward
    forward "/nested/forward", to: Forward

    get "/options/map", private: %{an_option: :a_value} do
      conn |> resp(200, inspect(conn.private))
    end

    forward "/options/forward", to: Forward, private: %{an_option: :a_value}

    match _ do
      conn |> resp(404, "oops")
    end

    defp verify_router_options(conn, _opts) do
      if conn.path_info == ["options", "map"] and is_nil(conn.private[:an_option]) do
        raise "should be able to read option after match"
      end
      conn
    end
  end

  use ExUnit.Case, async: true
  use Plug.Test

  test "dispatch root" do
    conn = call(Sample, conn(:get, "/"))
    assert conn.resp_body == "root"
  end

  test "dispatch literal segment" do
    conn = call(Sample, conn(:get, "/1/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch dynamic segment" do
    conn = call(Sample, conn(:get, "/2/value"))
    assert conn.resp_body == ~s("value")
  end

  test "dispatch dynamic segment with prefix" do
    conn = call(Sample, conn(:get, "/3/bar-value"))
    assert conn.resp_body == ~s("value")
  end

  test "dispatch glob segment" do
    conn = call(Sample, conn(:get, "/4/value"))
    assert conn.resp_body == ~s(["value"])

    conn = call(Sample, conn(:get, "/4/value/extra"))
    assert conn.resp_body == ~s(["value", "extra"])
  end

  test "dispatch glob segment with prefix" do
    conn = call(Sample, conn(:get, "/5/bar-value/extra"))
    assert conn.resp_body == ~s(["bar-value", "extra"])
  end

  test "dispatch custom route" do
    conn = call(Sample, conn(:get, "/6/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch with guards" do
    conn = call(Sample, conn(:get, "/7/a"))
    assert conn.resp_body == ~s("a")

    conn = call(Sample, conn(:get, "/7/ab"))
    assert conn.resp_body == ~s("ab")

    conn = call(Sample, conn(:get, "/7/abc"))
    assert conn.resp_body == ~s("abc")

    conn = call(Sample, conn(:get, "/7/abcd"))
    assert conn.resp_body == "oops"
  end

  test "dispatch after decoding guards" do
    conn = call(Sample, conn(:get, "/8/bar baz/bat"))
    assert conn.resp_body == "bat"

    conn = call(Sample, conn(:get, "/8/bar%20baz/bat bag"))
    assert conn.resp_body == "bat bag"

    conn = call(Sample, conn(:get, "/8/bar%20baz/bat%20bag"))
    assert conn.resp_body == "bat bag"
  end

  test "dispatch wrong verb" do
    conn = call(Sample, conn(:post, "/1/bar"))
    assert conn.resp_body == "oops"
  end

  test "dispatch with forwarding" do
    conn = call(Sample, conn(:get, "/forward"))
    assert conn.resp_body == "forwarded"
    assert conn.path_info == ["forward"]
  end

  test "dispatch with forwarding with custom call" do
    call(Sample, conn(:get, "/forward"))
    assert Process.get(:plug_forward_call, true)
  end

  test "dispatch with forwarding including slashes" do
    conn = call(Sample, conn(:get, "/nested/forward"))
    assert conn.resp_body == "forwarded"
    assert conn.path_info == ["nested", "forward"]
  end

  test "dispatch with forwarding modifies script_name" do
    conn = call(Sample, conn(:get, "/nested/forward/script_name"))
    assert conn.resp_body == "nested,forward"

    conn = call(Sample, conn(:get, "/step1/step2/script_name"))
    assert conn.resp_body == "step1,step2"
  end

  test "dispatch any verb" do
    conn = call(Sample, conn(:get, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:post, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:put, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:patch, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:delete, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:options, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:unknown, "/6/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatches based on host" do
    conn = call(Sample, conn(:get, "http://foo.bar/"))
    assert conn.resp_body == "foo.bar root"

    conn = call(Sample, conn(:get, "http://foo.other/"))
    assert conn.resp_body == "foo.* root"

    conn = call(Sample, conn(:get, "http://foo.other/script_name"))
    assert conn.resp_body == ""
  end

  test "dispatch not found" do
    conn = call(Sample, conn(:get, "/unknown"))
    assert conn.status == 404
    assert conn.resp_body == "oops"
  end

  @already_sent {:plug_conn, :sent}

  test "handle errors" do
    try do
      call(Sample, conn(:get, "/forward/throw"))
      flunk "oops"
    catch
      :throw, :oops ->
        assert_received @already_sent
        assigns = Process.get(:plug_handle_errors)
        assert assigns.status == 500
        assert assigns.kind   == :throw
        assert assigns.reason == :oops
        assert is_list assigns.stack
    end
  end

  test "handle errors translates exceptions to status code" do
    try do
      call(Sample, conn(:get, "/forward/raise"))
      flunk "oops"
    rescue
      Plug.Parsers.RequestTooLargeError ->
        assert_received @already_sent
        assigns = Process.get(:plug_handle_errors)
        assert assigns.status == 413
        assert assigns.kind   == :error
        assert assigns.reason.__struct__ == Plug.Parsers.RequestTooLargeError
        assert is_list assigns.stack
    end
  end

  test "handle errors when response was sent" do
    try do
      call(Sample, conn(:get, "/forward/send_and_exit"))
      flunk "oops"
    catch
      :exit, :oops ->
        assert_received @already_sent
        assert is_nil Process.get(:plug_handle_errors)
    end
  end

  test "assigns route options to private conn map" do
    conn = call(Sample, conn(:get, "/options/map"))
    assert conn.private[:an_option] == :a_value
    assert conn.resp_body =~ ~s(an_option: :a_value)
  end

  test "assigns options on forward" do
    conn = call(Sample, conn(:get, "/options/forward"))
    assert conn.private[:an_option] == :a_value
    assert conn.resp_body == "forwarded"
  end

  defp call(mod, conn) do
    mod.call(conn, [])
  end
end
