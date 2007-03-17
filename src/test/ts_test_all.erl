%%%-------------------------------------------------------------------
%%% File    : ts_test_all.erl
%%% Author  : Nicolas Niclausse <nicolas@niclux.org>
%%% Description : run all test functions
%%%
%%% Created : 17 Mar 2007 by Nicolas Niclausse <nicolas@niclux.org>
%%%-------------------------------------------------------------------
-module(ts_test_all).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

test() -> ok.

all_test_() -> [ts_test_recorder].
