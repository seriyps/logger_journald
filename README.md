logger_journald
===============

OTP [logger](http://erlang.org/doc/apps/kernel/logger_chapter.html) backend that sends log
events to Systemd's journald service.
Pure Erlang implementation (no C dependencies).

Usage
-----

Add to your `rebar.config`

```erlang
{deps, [logger_journald]}.
```

to your `sys.config`

```erlang
{kernel, [
    {logger, [
        {handler, my_handler, logger_journald_h, #{
            level => info,
            config => #{
              socket_path => "/run/systemd/journal/socket",  % optional
              defaults => #{"MY_KEY" => "My value",          % optional
                            "SYSLOG_IDENTIFIER" => my_release}
            }
        }}
    ]}
]}
```

or do this somewhere in your code

```erlang
logger:add_handler(my_handler, logger_journald_h,
                   #{config => #{defaults => #{"SYSLOG_IDENTIFIER" => my_release}}}).
```

I'd recommend to add at least one key to `defaults` to uniquely identify your application. The
recommended key name for that is `SYSLOG_IDENTIFIER`.

Other `logger:handler_config()` options (`level`, `filters`) should also work, but not
`formatter`, because format of `journald` packet is restricted.

Then start your app and send some logs. They can be seen, eg, like this (see `man journalctl`):

```bash
$ journalctl -f -o verbose _COMM=beam.smp SYSLOG_IDENTIFIER=my_release
```

Multiple instances of `logger_journald_h` handler can be started.

It's not currently possible to set `logger_journald_h` as `default` handler via `sys.config`,
because `sys.config` is applied at `kernel` application start time and `logger_journald`
application depends on `kernel` application (sort of cyclic dependency).

There is also [journald_log](src/journald_log.erl) module available, which provides a thin wrapper
with limited API for journald's control socket.

How it works?
-------------

When `logger_journald` application is started, it creates an empty supervisor.
When `logger:add_handler/3` is called, `logger_journald` starts a new `gen_server` under
this supervisor, which holds open `gen_udp` UNIX-socket open to journald and some internal state.

When you call `logger:log` (or use `?LOG*` macro), your log message is converted to be a flat
key-value structure in the same process where `log` is called and then sent to this `gen_server`,
which writes it to journld's socket via `gen_udp`.

Be careful! All the log messages targeting one handler are sent through the single gen_server!
There is no backpressure support at the moment!

The way (`logger:log_event()`)[http://erlang.org/doc/man/logger.html#type-log_event] is converted
to a journald flat key-value structure is following:

* `msg` is sent as `MESSAGE` field
  * If `msg` is a `{report, logger:report()}`, then it is converted to a string with
    `logger:report_cb()` function provided in `meta`.
  * If `msg` is `{io:format(), [any()]}`, it is converted to a string with `io_lib:format/2`
* `level` is converted to syslog's numerical value between 0 ("emergency") and 7 ("debug") and is
  sent as `PRIORITY` field
* `meta` fields are encoded in a following way
  * `file`, `line` and `mfa` are encoded as `CODE_FILE`, `CODE_LINE` and `CODE_FUNC` (in
    `Module:Function/Arity` form)
  * `time` is encoded in RFC-3339 format and sent as `SYSLOG_TIMESTAMP` field
  * `pid` is encoded as a string and sent as `ERL_PID` field
  * `gl` is encoded the same as `pid` and sent as `ERL_GROUP_LEADER`
  * `domain` is encoded as dot-separated string (eg `[otp, sasl]` -> `otp.sasl`) and sent as
    `ERL_DOMAIN`
  * all the custom metadata field names are converted to uppercase string and values are formatted
    with `io_lib:format("~p", [Value])`

Encoder works quite well with iolists / iodata values (they are sent as is), but it's slightly
more optimized for a binary values.

Development
-----------

Please, run the following before committing

```
rebar3 as dev fmt
rebar3 as dev lint
rebar3 eunit
rebar3 edoc
rebar3 dialyzer
```
