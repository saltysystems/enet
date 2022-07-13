-module(enet_channel_srv).
-behaviour(gen_server).

-include("enet_commands.hrl").

% API
-export([
         start_link/2,
         stop/1,
         set_worker/2,
         recv_unsequenced/2,
         send_unsequenced/2,
         recv_unreliable/2,
         send_unreliable/2,
         recv_reliable/2,
         send_reliable/2
        ]).

% required gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

% records
-record(state,
        {
          id,
          peer,
          worker,
          incoming_reliable_sequence_number = 1,
          incoming_unreliable_sequence_number = 0,
          outgoing_reliable_sequence_number = 1,
          outgoing_unreliable_sequence_number = 1,
          reliable_windows, %% reliableWindows [ENET_PEER_RELIABLE_WINDOWS] (uint16 * 16 = 32 bytes)
          used_reliable_windows = 0,
          sys_parent,
          sys_debug
        }).


-spec start_link(term(), term()) -> Result when
      Result :: {ok, Pid :: pid()} | 
               ignore | 
               {error, Reason :: term()}.
start_link(ID, Peer) ->
    % start an anonymous gen_server
    gen_server:start_link(?MODULE, [ID, Peer], []).

-spec stop(pid()) -> ok.
stop(Channel) ->
    gen_server:stop(Channel).

set_worker(Channel, Worker) ->
    gen_server:cast(Channel, {set_worker, Worker}).

recv_unsequenced(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_unsequenced, {H,C}}).

-spec send_unsequenced(pid(), term()) -> ok.
send_unsequenced(Channel, Data) ->
    gen_server:cast(Channel, {send_unsequenced, Data}).

recv_unreliable(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_unreliable, {H,C}}).

-spec send_unreliable(pid(), term()) -> ok.
send_unreliable(Channel, Data) ->
    gen_server:cast(Channel, {send_unreliable, Data}).

recv_reliable(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_reliable, {H,C}}).

-spec send_reliable(pid(), term()) -> ok.
send_reliable(Channel, Data) ->
    gen_server:cast(Channel, {send_reliable, Data}).

% gen_server callbacks

init([ID, Peer]) -> 
    S0 = #state{
               id = ID,
               peer = Peer
              },
    {ok, S0}.
               
handle_call(_Msg, _From, S0) ->
    {reply, ok, S0}.

handle_cast({set_worker, Worker}, S0) ->
    S1 = S0#state{worker = Worker},
    {noreply, S1};
handle_cast({recv_unsequenced, { #command_header{ unsequenced = 1 }, C = #unsequenced{}}}, S0) ->
    Worker = S0#state.worker,
    ID = S0#state.id,
    Worker ! {enet, ID, C},
    {noreply, S0};
handle_cast({send_unsequenced, Data}, S0) ->
    ID = S0#state.id,
    Peer = S0#state.peer,
    {H,C} = enet_command:send_unsequenced(ID, Data),
    ok = enet_peer:send_command(Peer, {H,C}),
    {noreply, S0};
handle_cast({recv_unreliable, {#command_header{}, C = #unreliable{sequence_number = N}}}, S0) ->
    Worker = S0#state.worker,
    ID = S0#state.id,
    S1 = 
    if N < S0#state.incoming_unreliable_sequence_number ->
           %% Data is old - drop it and continue.
           S0;
       true -> 
           Worker ! {enet, ID, C},
           S0#state{incoming_unreliable_sequence_number = N}
    end,
    {noreply, S1};
handle_cast({send_unreliable, Data}, S0) ->
    ID = S0#state.id,
    Peer = S0#state.peer,
    N = S0#state.outgoing_unreliable_sequence_number,
    {H,C} = enet_command:send_unreliable(ID, N, Data),
    ok = enet_peer:send_command(Peer, {H, C}),
    S1 = S0#state{ outgoing_reliable_sequence_number = N + 1 },
    {noreply, S1};
handle_cast({recv_reliable, {#command_header{reliable_sequence_number = N}, C = #reliable{}}}, S0) when
    N =:= S0#state.incoming_reliable_sequence_number ->
        ID = S0#state.id,
        Worker = S0#state.worker,
        Worker ! {enet, ID, C},
        S1 = S0#state{incoming_reliable_sequence_number = N+1},
        {noreply, S1};
handle_cast({send_reliable, Data}, S0) -> 
    ID = S0#state.id,
    Peer = S0#state.peer,
    N = S0#state.outgoing_reliable_sequence_number,
    {H,C} = enet_command:send_reliable(ID, N, Data),
    ok = enet_peer:send_command(Peer, {H,C}),
    S1 = S0#state{outgoing_reliable_sequence_number = N+1},
    {noreply, S1};
handle_cast(Msg, S0) ->
    logger:debug("Unhandled message: ~p", [Msg]),
    logger:debug("Current state: ~p", [S0]),
    {noreply, S0}.

handle_info(Msg, S0) ->
    logger:debug("Got unhandled msg: ~p", [Msg]),
    {noreply, S0}.

terminate(_Reason, _S0) ->
    ok.

code_change(_OldVsn, S0, _Extra) ->
    {ok, S0}.
