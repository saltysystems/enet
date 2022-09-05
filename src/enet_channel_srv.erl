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

% enet_uint16 ENetPeer::outgoingReliableSequenceNumber
-define(ENET_MAX_SEQ_INDEX, 65536).
% ENET_PEER_RELIABLE_WINDOW_SIZE = 0x1000,
-define(ENET_PEER_RELIABLE_WINDOW_SIZE, 16#1000).

% records
-record(state, {
    id,
    peer,
    worker,
    incoming_reliable_sequence_number = 1,
    incoming_unreliable_sequence_number = 1,
    outgoing_reliable_sequence_number = 1,
    outgoing_unreliable_sequence_number = 1,
    %% reliableWindows [ENET_PEER_RELIABLE_WINDOWS] (uint16 * 16 = 32 bytes)
    reliable_window = [],
    unreliable_window = [],
    sys_parent,
    sys_debug
}).

-spec start_link(term(), term()) -> Result when
    Result ::
        {ok, Pid :: pid()}
        | ignore
        | {error, Reason :: term()}.
start_link(ID, Peer) ->
    % start an anonymous gen_server
    gen_server:start_link(?MODULE, [ID, Peer], []).

-spec stop(pid()) -> ok.
stop(Channel) ->
    gen_server:stop(Channel).

set_worker(Channel, Worker) ->
    gen_server:cast(Channel, {set_worker, Worker}).

recv_unsequenced(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_unsequenced, {H, C}}).

-spec send_unsequenced(pid(), term()) -> ok.
send_unsequenced(Channel, Data) ->
    gen_server:cast(Channel, {send_unsequenced, Data}).

recv_unreliable(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_unreliable, {H, C}}).

-spec send_unreliable(pid(), term()) -> ok.
send_unreliable(Channel, Data) ->
    gen_server:cast(Channel, {send_unreliable, Data}).

recv_reliable(Channel, {H, C}) ->
    gen_server:cast(Channel, {recv_reliable, {H, C}}).

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
handle_cast(
    {recv_unsequenced, {#command_header{unsequenced = 1}, C = #unsequenced{}}},
    S0
) ->
    Worker = S0#state.worker,
    ID = S0#state.id,
    Worker ! {enet, ID, C},
    {noreply, S0};
handle_cast({send_unsequenced, Data}, S0) ->
    ID = S0#state.id,
    Peer = S0#state.peer,
    {H, C} = enet_command:send_unsequenced(ID, Data),
    ok = enet_peer:send_command(Peer, {H, C}),
    {noreply, S0};
handle_cast({recv_unreliable, {#command_header{}, C = #unreliable{sequence_number = N}}}, S0) ->
    Expected = S0#state.incoming_unreliable_sequence_number,
    if
        N =:= Expected ->
            Worker = S0#state.worker,
            ID = S0#state.id,
            Worker ! {enet, ID, C},
            % Dispatch any buffered packets
            Window = S0#state.unreliable_window,
            SortedWindow = wrapped_sort(Window),
            {NextSeq, NewWindow} = unreliable_dispatch(N, SortedWindow, ID, Worker),
            S1 = S0#state{incoming_unreliable_sequence_number = NextSeq, unreliable_window = NewWindow},
            {noreply, S1};
        % The guard is a bit complex because we need to account for wrapped
        % sequence numbers. Examples:
        % N = 5, Expected = 4. -> 5-4 = 1.
        % N = 1, Expected = 65534 -> 1 - 65534 = -65533. 
        N > Expected; N - Expected =< -?ENET_MAX_SEQ_INDEX/2  ->
            %% Data is newer than expected - buffer it 
            logger:debug("Buffer ahead-of-sequence packet. Recv: ~p. Expect: ~p.", [N, Expected]),
            UnreliableWindow0 = S0#state.unreliable_window,
            S1 = S0#state{unreliable_window = [ {N, C} | UnreliableWindow0 ]}, 
            {noreply, S1};
        % Examples:
        % N = 4, Expected = 5. -> 4-5 = -1 
        % N = 65535, Expected 2. -> 65535-2 = 65533.
        N < Expected; N - Expected >= ?ENET_MAX_SEQ_INDEX/2  ->
            %% Data is old - drop it and continue.
            logger:debug("Discard outdated packet. Recv: ~p. Expect: ~p", [N, Expected]),
            {noreply, S0};
        % We should crash if no conditions are satisfied
        true ->
            {stop, unexpected}
    end;
handle_cast({send_unreliable, Data}, S0) ->
    ID = S0#state.id,
    Peer = S0#state.peer,
    N = S0#state.outgoing_unreliable_sequence_number,
    {H, C} = enet_command:send_unreliable(ID, N, Data),
    ok = enet_peer:send_command(Peer, {H, C}),
    S1 = S0#state{outgoing_reliable_sequence_number = maybe_wrap(N + 1)},
    {noreply, S1};
handle_cast({recv_reliable, _Data}, S0 = #state{reliable_window = W}) when
    length(W) > ?ENET_PEER_RELIABLE_WINDOW_SIZE
->
    {stop, out_of_sync, S0};
handle_cast({recv_reliable, {#command_header{reliable_sequence_number = N}, C = #reliable{}}}, S0) ->
    Expected = S0#state.incoming_reliable_sequence_number,
    if
        N =:= Expected ->
            ID = S0#state.id,
            % Dispatch this packet
            Worker = S0#state.worker,
            Worker ! {enet, ID, C},
            % Dispatch any buffered packets
            Window = S0#state.reliable_window,
            SortedWindow = wrapped_sort(Window),
            {NextSeq, NewWindow} = reliable_dispatch(N, SortedWindow, ID, Worker),
            S1 = S0#state{incoming_reliable_sequence_number = NextSeq, reliable_window = NewWindow},
            {noreply, S1};
        % The guard is a bit complex because we need to account for wrapped
        % sequence numbers. Examples:
        % N = 5, Expected = 4. -> 5-4 = 1.
        % N = 1, Expected = 65534 -> 1 - 65534 = -65533. 
        N > Expected; N - Expected =< -?ENET_MAX_SEQ_INDEX/2  ->
            logger:debug("Buffer ahead-of-sequence packet. Recv: ~p. Expect: ~p.", [N, Expected]),
            ReliableWindow0 = S0#state.reliable_window,
            S1 = S0#state{reliable_window = [{N, C} | ReliableWindow0]},
            {noreply, S1};
        % Examples:
        % N = 4, Expected = 5. -> 4-5 = -1 
        % N = 65535, Expected 2. -> 65535-2 = 65533.
        N < Expected; N - Expected >= ?ENET_MAX_SEQ_INDEX/2  ->
            logger:debug("Discard outdated packet. Recv: ~p. Expect: ~p", [N, Expected]),
            {noreply, S0};
        % We should crash if no conditions are satisfied
        true ->
            {stop, unexpected}
    end;
handle_cast({send_reliable, Data}, S0) ->
    ID = S0#state.id,
    Peer = S0#state.peer,
    N = S0#state.outgoing_reliable_sequence_number,
    {H, C} = enet_command:send_reliable(ID, N, Data),
    ok = enet_peer:send_command(Peer, {H, C}),
    S1 = S0#state{outgoing_reliable_sequence_number = maybe_wrap(N + 1)},
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

% Internal
%

-spec reliable_dispatch(pos_integer(), list(), pos_integer(), pid()) ->
    {pos_integer(), list()}.
reliable_dispatch(CurSeq, [], _ChannelID, _Worker) ->
    NextSeq = maybe_wrap(CurSeq + 1),
    {NextSeq, []};
reliable_dispatch(CurSeq, Window = [{Seq1, D1} | RemainingWindow], ChannelID, Worker) ->
    % If the buffered item comes immediately after the current sequence number,
    % dispatch the next packet.
    NextSeq = maybe_wrap(CurSeq + 1),
    case NextSeq == Seq1 of
        true ->
            % Dispatch the packet
            logger:debug("Dispatching queued packet ~p", [Seq1]),
            Worker ! {enet, ChannelID, D1},
            reliable_dispatch(NextSeq, RemainingWindow, ChannelID, Worker);
        _ ->
            % The first packet in the window is not the one we're looking for,
            % so just return.
            {NextSeq, Window}
    end.

-spec unreliable_dispatch(pos_integer(), list(), pos_integer(), pid()) ->
    {pos_integer(), list()}.
unreliable_dispatch(CurSeq, [], _ChannelID, _Worker) ->
    % Nothing left to dispatch
    NextSeq = maybe_wrap(CurSeq + 1),
    {NextSeq, []};
unreliable_dispatch(CurSeq, [{Seq1, D1} | RemainingWindow], ChannelID, Worker) ->
    % Dispatch the next packet, assuming the window is already sorted.
    NextSeq = maybe_wrap(CurSeq + 1),
    logger:debug("Dispatching queued packet ~p", [Seq1]),
    Worker ! {enet, ChannelID, D1},
    unreliable_dispatch(NextSeq, RemainingWindow, ChannelID, Worker).

maybe_wrap(Seq) ->
    % Must wrap at 16-bits.
    (Seq) rem ?ENET_MAX_SEQ_INDEX.

wrapped_sort(List) ->
    % Keysort while preserving order through 16-bit integer wrapping.
    F = fun({A, _}, {B, _}) ->
        Compare = B - A,
        if
            Compare > 0, Compare =< ?ENET_MAX_SEQ_INDEX / 2 ->
                true;
            Compare < 0, Compare =< -?ENET_MAX_SEQ_INDEX / 2 ->
                true;
            true ->
                false
        end
    end,
    lists:sort(F, List).
