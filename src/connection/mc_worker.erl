-module(mc_worker).
-behaviour(gen_server).

-include("mongo_protocol.hrl").

-export([start_link/1, disconnect/1, hibernate/1]).
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-record(state, {
  socket :: gen_tcp:socket() | ssl:sslsocket(),
  request_storage = dict:new() :: dict:dict(),
  buffer = <<>> :: binary(),
  conn_state,
  net_module :: ssl | get_tcp
}).

-spec start_link(proplists:proplist()) -> {ok, pid()}.
start_link(Options) ->
  proc_lib:start_link(?MODULE, init, [Options]).

%% Make worker to go into hibernate. Any next call will wake it.
%% It should be done if you have problems with memory while fetching > 64B binaries from db.
-spec hibernate(pid()) -> ok.
hibernate(#{pool := Worker}) ->
  hibernate(Worker);
hibernate(Worker) ->
  gen_server:cast(Worker, hibernate).

%% halt worker, close tcp connection
disconnect(Worker) ->
  gen_server:cast(Worker, halt).

init(Options) ->
  proc_lib:init_ack({ok, self()}),
  {ok, Socket} = mc_auth:connect_to_database(Options),
  ConnState = form_state(Options),
  try_register(Options),
  NetModule = get_set_opts_module(Options),
  Login = mc_utils:get_value(login, Options),
  Password = mc_utils:get_value(password, Options),
  mc_auth:auth(Socket, Login, Password, ConnState#conn_state.database, NetModule),
  gen_server:enter_loop(?MODULE, [], #state{socket = Socket, conn_state = ConnState, net_module = NetModule}).

handle_call(NewState = #conn_state{}, _, State = #state{conn_state = OldState}) ->  % update state, return old
  {reply, {ok, OldState}, State#state{conn_state = NewState}};
handle_call(#ensure_index{collection = Coll, index_spec = IndexSpec}, _,
    State = #state{conn_state = ConnState, socket = Socket, net_module = NetModule}) -> % ensure index request with insert request
  Key = maps:get(<<"key">>, IndexSpec),
  Defaults = {<<"name">>, mc_worker_logic:gen_index_name(Key), <<"unique">>, false, <<"dropDups">>, false},
  Index = bson:update(<<"ns">>, mongo_protocol:dbcoll(ConnState#conn_state.database, Coll), bson:merge(IndexSpec, Defaults)),
  {ok, _} = mc_worker_logic:make_request(
    Socket,
    NetModule,
    ConnState#conn_state.database,
    #insert{collection = mc_worker_logic:update_dbcoll(Coll, <<"system.indexes">>),
      documents = [Index]}),
  {reply, ok, State};
handle_call(Request, From, State) when is_record(Request, insert); is_record(Request, update); is_record(Request, delete) ->  % write requests (deprecated)
  process_write_request(Request, From, State);
handle_call(Request, From, State) when is_record(Request, 'query'); is_record(Request, getmore) -> % read requests
  process_read_request(Request, From, State);
handle_call(Request, _, State = #state{socket = Socket, conn_state = ConnState, net_module = NetModule})
  when is_record(Request, killcursor) ->
  {ok, _} = mc_worker_logic:make_request(Socket, NetModule, ConnState#conn_state.database, Request),
  {reply, ok, State};
handle_call({stop, _}, _From, State) -> % stop request
  {stop, normal, ok, State}.

%% @hidden
handle_cast(halt, State) ->
  {stop, normal, State};
handle_cast(hibernate, State) ->
  {noreply, State, hibernate};
handle_cast(_, State) ->
  {noreply, State}.

%% @hidden
handle_info({Net, _Socket, Data}, State = #state{request_storage = RequestStorage}) when Net =:= tcp; Net =:= ssl ->
  Buffer = <<(State#state.buffer)/binary, Data/binary>>,
  {Responses, Pending} = mc_worker_logic:decode_responses(Buffer),
  UReqStor = mc_worker_logic:process_responses(Responses, RequestStorage),
  {noreply, State#state{buffer = Pending, request_storage = UReqStor}};
handle_info({NetR, _Socket}, State) when NetR =:= tcp_closed; NetR =:= ssl_closed ->
  {stop, tcp_closed, State};
handle_info({NetR, _Socket, Reason}, State) when NetR =:= tcp_errror; NetR =:= ssl_error ->
  {stop, Reason, State}.

%% @hidden
terminate(_, State = #state{net_module = NetModule}) ->
    catch NetModule:close(State#state.socket).

%% @hidden
code_change(_Old, State, _Extra) ->
  {ok, State}.

%% @private
process_read_request(Request, From, State =
  #state{socket = Socket, request_storage = RequestStorage, conn_state = CS, net_module = NetModule}) ->
  {UpdReq, Selector} = get_query_selector(Request, CS),
  {ok, Id} = mc_worker_logic:make_request(Socket, NetModule, CS#conn_state.database, UpdReq),
  case get_write_concern(Selector) of
    {<<"w">>, 0} -> %no concern request
      {reply, #reply{cursornotfound = false, queryerror = false, cursorid = 0, documents = [#{<<"ok">> => 1}]}, State};
    _ ->  %ordinary request with response
      RespFun = mc_worker_logic:get_resp_fun(UpdReq, From),  % save function, which will be called on response
      URStorage = dict:store(Id, RespFun, RequestStorage),
      {noreply, State#state{request_storage = URStorage}}
  end.

%% @deprecated
%% @private
process_write_request(Request, _,
    State = #state{socket = Socket, conn_state = #conn_state{write_mode = unsafe, database = Db}, net_module = NetModule}) ->
  {ok, _} = mc_worker_logic:make_request(Socket, NetModule, Db, Request),
  {reply, ok, State};
process_write_request(Request, From,
    State = #state{socket = Socket, conn_state = #conn_state{write_mode = Safe, database = Db}, request_storage = ReqStor, net_module = NetModule}) ->
  Params = case Safe of safe -> {}; {safe, Param} -> Param end,
  ConfirmWrite =
    #'query'
    { % check-write read request
      batchsize = -1,
      collection = mc_worker_logic:update_dbcoll(mc_worker_logic:collection(Request), <<"$cmd">>),
      selector = bson:append({<<"getlasterror">>, 1}, Params)
    },
  {ok, Id} = mc_worker_logic:make_request(
    Socket, NetModule, Db, [Request, ConfirmWrite]), % ordinary write request
  RespFun = mc_worker_logic:get_resp_fun(Request, From),
  UReqStor = dict:store(Id, RespFun, ReqStor),  % save function, which will be called on response
  {noreply, State#state{request_storage = UReqStor}}.

%% @private
get_query_selector(Query = #query{selector = Selector, sok_overriden = true}, CS) ->
  {Query#'query'{slaveok = CS#conn_state.read_mode =:= slave_ok}, Selector};
get_query_selector(Query = #query{selector = Selector, sok_overriden = false}, _) ->
  {Query, Selector};
get_query_selector(GetMore, _) -> {GetMore, {}}.

%% @private
get_write_concern(#{<<"writeConcern">> := N}) -> N;
get_write_concern(Selector) when is_tuple(Selector) ->
  bson:lookup(<<"writeConcern">>, Selector);
get_write_concern(_) -> undefined.

%% @private
%% Parses proplist to record
form_state(Options) ->
  Database = mc_utils:get_value(database, Options, <<"admin">>),
  RMode = mc_utils:get_value(r_mode, Options, master),
  WMode = mc_utils:get_value(w_mode, Options, unsafe),
  #conn_state{database = Database, read_mode = RMode, write_mode = WMode}.

%% @private
%% Register this process if needed
try_register(Options) ->
  case lists:keyfind(register, 1, Options) of
    false -> ok;
    {_, Name} when is_atom(Name) -> register(Name, self());
    {_, RegFun} when is_function(RegFun) -> RegFun(self())
  end.

%% @private
get_set_opts_module(Options) ->
  case mc_utils:get_value(ssl, Options, false) of
    true -> ssl;
    false -> gen_tcp
  end.