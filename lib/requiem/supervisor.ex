defmodule Requiem.Supervisor do
  @moduledoc """
  Root supervisor for all Requiem process tree.
  """
  use Supervisor
  alias Requiem.AddressTable
  alias Requiem.Config
  alias Requiem.QUIC
  alias Requiem.ConnectionRegistry
  alias Requiem.ConnectionSupervisor
  alias Requiem.DispatcherSupervisor
  alias Requiem.DispatcherRegistry
  alias Requiem.SenderSupervisor
  alias Requiem.SenderRegistry
  alias Requiem.Transport

  @spec child_spec(module, atom) :: Supervisor.child_spec()
  def child_spec(handler, otp_app) do
    %{
      id: handler |> name(),
      start: {__MODULE__, :start_link, [handler, otp_app]},
      type: :supervisor
    }
  end

  @spec start_link(module, Keyword.t()) :: Supervisor.on_start()
  def start_link(handler, otp_app) do
    name = handler |> name()
    Supervisor.start_link(__MODULE__, [handler, otp_app], name: name)
  end

  @impl Supervisor
  def init([handler, otp_app]) do
    handler |> Config.init(otp_app)
    handler |> QUIC.setup()

    if handler |> Config.get(:allow_address_routing) do
      handler |> AddressTable.init()
    end

    handler |> children() |> Supervisor.init(strategy: :one_for_one)
  end

  @spec children(module) :: [:supervisor.child_spec() | {module, term} | module]
  def children(handler) do
    [
      {Registry, keys: :unique, name: ConnectionRegistry.name(handler)},
      {Registry, keys: :unique, name: DispatcherRegistry.name(handler)},
      {Registry, keys: :unique, name: SenderRegistry.name(handler)},
      {ConnectionSupervisor, handler},
      {DispatcherSupervisor,
       [
         handler: handler,
         transport: Transport,
         token_secret: handler |> Config.get!(:token_secret),
         conn_id_secret: handler |> Config.get!(:connection_id_secret),
         number_of_dispatchers: handler |> Config.get!(:dispatcher_pool_size),
         allow_address_routing: handler |> Config.get!(:allow_address_routing)
       ]},
      {SenderSupervisor,
       [
         handler: handler,
         number_of_senders: handler |> Config.get!(:socket_pool_size)
       ]},
      {Transport,
       [
         handler: handler,
         port: handler |> Config.get!(:port),
         number_of_dispatchers: handler |> Config.get!(:dispatcher_pool_size),
         event_capacity: handler |> Config.get!(:socket_event_capacity),
         host: handler |> Config.get!(:host),
         polling_timeout: handler |> Config.get!(:socket_polling_timeout)
       ]}
    ]
  end

  defp name(handler),
    do: Module.concat(handler, __MODULE__)
end
