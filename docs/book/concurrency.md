# Tasks, channels, and actors

This chapter runs work concurrently with tasks, connects tasks with
channels, keeps state in actors, and handles cancellation.

## Tasks

`spawn` starts an expression as a task and returns a `Task` at once. `await`
waits for the task and gives its value. `scope` owns the tasks spawned
inside it:

```gene runnable
(scope
  (let left (spawn (+ 10 20)))
  (let right (spawn (+ 30 40)))
  (+ (await left) (await right)))
# 100
```

- When the scope's body finishes normally, the scope waits for its tasks
  before it returns.
- When the body fails, the scope cancels the tasks still running, waits for
  their cleanup, and then lets the failure continue.
- So no task outlives the scope that started it, unless it was started
  detached on purpose.

`await` raises the task's failure in the awaiting code, so errors handle as
they would in a direct call:

```gene runnable
(type Boom : Error)
(try
  (scope
    (let task (spawn (fail (Boom ^_msg "worker failed"))))
    (await task))
  catch Boom $err/.message)
# "worker failed"
```

`(task .join)` waits without raising, and returns a `TaskOutcome`: `ok`,
`error`, `fault`, or `cancelled`. `task/.done?` tests whether the task has
finished without waiting:

```gene runnable
(scope
  (let task (spawn 5))
  [(task .join) task/.done?])
# [#(TaskOutcome/ok 5) true]
```

Tasks are concurrent, which is not the same as each running on its own OS
thread. Tasks on one lane take turns, switching only where a task waits or
at a function call or loop iteration once its time slice is spent.

## Channels

A channel carries values between tasks in order. `^capacity` bounds how many
values it buffers. `send` waits while the channel is full, and `recv` waits
while it is empty:

```gene runnable
(scope
  (let box ($channel ^capacity 2))
  (spawn (do
    (box .send 1)
    (box .send 2)
    box/.close))
  [box/.recv box/.recv])
# [1 2]
```

> **Watch out:** `spawn` takes one expression. `(spawn a b)` fails with
> `spawn expects one expression`; group several with `do`.

- `try_send` and `try_recv` never wait. `try_send` returns `false` when the
  channel is full, and `try_recv` returns a `TryRecv` value.
- `close` ends the channel. A `recv` on a closed, empty channel raises
  `ChannelClosed`.

```gene runnable
(let box ($channel ^capacity 1))
[(box .try_send 1) (box .try_send 2) box/.try_recv]
# [true false #(TryRecv/value 1)]
```

> **Watch out:** the capacity is a named argument. `($channel 2)` fails with
> `channel expects no positional arguments`; write `($channel ^capacity 2)`.

Values sent through channels and to actors must be safe to share (`Send`):
immutable data, or values of a type that declares `^impl [Send]`.

## Shared state in a cell

A `Cell` holds one value that can be replaced, and tasks that share the cell
see each other's writes. `$cell` makes one, `.get` reads it, and `.set`
replaces the value:

```gene runnable
(let hits ($cell 0))
(scope
  (spawn (hits .set (+ hits/.get 1)))
  (spawn (hits .set (+ hits/.get 1))))
hits/.get
# 2
```

Code between two waits runs without interruption on its lane, so the read
and the write above cannot interleave. A sequence that calls a Gene function
or loops between its read and its write has no such guarantee. Guard it with
a gate: `(let gate ($sync/gate))` makes one, and `(gate (fn [] …))` runs the
function while no other caller of that gate is inside it.

## Cancellation

`task/.cancel` asks a task to stop. The task stops at its next wait, and its
`ensure` blocks run on the way out:

```gene runnable
(let cleaned ($cell false))
(scope
  (let task (spawn (try ($sleep 60_000) ensure (cleaned .set true))))
  ($sleep 1)
  task/.cancel)
cleaned/.get
# true
```

`$sleep` takes milliseconds. Cancellation is not an error: no `catch` clause
sees it, so a `catch Error` cannot swallow it, while `ensure` and `unwind`
still run.

## Actors

An actor holds state and handles its messages one at a time.
`$actor/spawn` takes an `^init` function for the first state and a
`^handle` function, which receives the context, the state, and a message,
and returns the next step:

```gene runnable
(fn add_to [ctx state msg]
  ($actor/continue (+ state msg)))
(let counter ($actor/spawn ^init (fn [] 0) ^handle add_to))
(counter .send 2)
(counter .send 5)
counter/.snapshot/state
# 7
```

- `($actor/continue state)` keeps the actor running with the new state.
- `($actor/stop)` ends the actor.
- `send` queues a message. `ask` sends a message that carries a one-shot
  `ReplyTo` and returns a Task for the reply.

Because an actor handles one message at a time, its state needs no locking.
A `supervisor` form owns actors and restarts or stops one whose handler
fails.

## Events

An event bus delivers each published event to the subscribers of its type,
and of its parent types:

```gene runnable
(type UserJoined : $event/Event ^props {^name Str})
(let seen ($cell []))
(let bus ($event/Bus))
(bus .subscribe UserJoined
  (fn [event] ((seen .get) .push event/name)))
(bus .publish (UserJoined ^name "Ada"))
(bus .close)
(seen .get)
# ["Ada"]
```

Publishing makes an immutable snapshot of the event. Cancel a subscription,
or close the bus, to release its handlers.
