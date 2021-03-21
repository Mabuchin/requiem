defmodule RequiemTest.ConnectionTest do
  use ExUnit.Case, async: true

  alias Requiem.QUIC
  alias Requiem.QUIC.Config
  alias Requiem.QUIC.Socket
  alias Requiem.QUIC.Connection

  test "connection NIF" do
    module = Module.concat(__MODULE__, Test1)

    scid = :crypto.strong_rand_bytes(20)
    odcid = :crypto.strong_rand_bytes(20)

    {:ok, peer} = Socket.address_from_string("192.168.0.1:4000")
    c = Config.new()

    try do
      assert QUIC.init(module) == :ok
      {:ok, conn} = Connection.accept(module, c, scid, odcid, peer)

      try do
        assert Connection.is_closed?(conn) == false
        assert Connection.close(conn, false, 0x1, "") == :ok
        assert Connection.is_closed?(conn) == true
      after
        Connection.destroy(conn)
      end
    after
      Config.destroy(c)
    end
  end

  test "multiple connection state" do
    module = Module.concat(__MODULE__, Test2)
    assert QUIC.init(module) == :ok

    scid1 = :crypto.strong_rand_bytes(20)
    odcid1 = :crypto.strong_rand_bytes(20)

    scid2 = :crypto.strong_rand_bytes(20)
    odcid2 = :crypto.strong_rand_bytes(20)

    {:ok, peer} = Socket.address_from_string("192.168.0.1:4000")

    c = Config.new()

    try do
      {:ok, conn1} = Connection.accept(module, c, scid1, odcid1, peer)
      {:ok, conn2} = Connection.accept(module, c, scid2, odcid2, peer)

      try do
        assert Connection.is_closed?(conn1) == false
        assert Connection.is_closed?(conn2) == false
        assert Connection.close(conn1, false, 0x1, "") == :ok
        assert Connection.is_closed?(conn1) == true
        assert Connection.is_closed?(conn2) == false

        assert Connection.close(conn2, false, 0x1, "") == :ok

        assert Connection.is_closed?(conn1) == true
        assert Connection.is_closed?(conn2) == true

        # duplicated close command
        assert Connection.close(conn1, false, 0x1, "") == {:error, :already_closed}
        assert Connection.close(conn2, false, 0x1, "") == {:error, :already_closed}
      after
        Connection.destroy(conn1)
        Connection.destroy(conn2)
      end
    after
      Config.destroy(c)
    end
  end
end
