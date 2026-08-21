 for that repo (I don't havbe a name yet for the tool, we can give it some temporary project name first and think about it again before publishing it)

  so, basically the goal is to have a storage solution that is like a distributed ledger or dqlite or sth

  basically, what it should support

  - append only data entries
  - ttl on entries
  - settings/flags for the storage system, which allows configuring
  - ttl - whether entries with ttl reached are completely deleted from the ledger or marked stale
  - ttl - to enable/disable ttl enforcement. so it is possible to not use ttl, or not enforce it for every entry - but also possible to enforce it for all entries in the schema
  - concurrency handling - different modes of concurrency handling and an option to enable reloading/changing them on the fly. if it's disabled, changing the concurrency handling mode on the fly is not allowed. when enabled, it is possible
    concurrency handling modes / leader election - as it is append only for now, concurrency should be relatively simple to handle. however, there needs to be some kind of leader election as well as config of leader election mode
    we need to be able to run it as standalone, as well as scale up from there! in that case, it can be difficult to know who is the leader. for example using 2 instances, common protocols like raft or etcd will have troubles to know who is the leader. so
  - one mode would be that it is based on who "joined" the ledger the earliest, automatically detected. which will work for single instance or 2 instances. or other uneven numbers. based on who joined earlier, the priority of who is leader is set.
     -> that will require a mechanism, to make sure it cannot be spoofed by any member to falsify their join date!
    another mode will be to simply define in the config, that in case of conflict. who are the highest authority members (by ip/dns name or whatever!)
    - for that one, it can be also done that for a two instance/node ledger, we can define a specific one who is the leader, to make sure it will work
    - it will also help to allow us to run a single instance only as it is its own leader
    - also, for any even number of instances writing the ledger, let's say we have 6 nodes - then we can say which 1, 3, 5 or whatever uneven number will have the leadership
      also, a combination of the modes, let's say for example 5 leaders are set, but then we still within those 5 prioritize by join time. or perhaps we can also prioritize by who has the latest entries, but also definitely has the full state of the ledger

  as distirbuted ledger, append only, every node will have the full state of course. that's why we want to be able to have it muteable or have a toggle to allow mutability for automatic cleanup via TTL or marking entries stale (where a specific instance can only mark their own added entries as stale!!) which then get removed/cleanup as well

  if concurrency handling  / leader election is allowed to change during ruintime via mentioned config. it will enable to seamlessly switch between the different modes and scale all the way from 1 -> n seamlessly, no matter if it's even or uneven number

  write the draft docs/prd and stuff for the design and anything else, any information we already have and also a doc with open questions and hat else you can think of that might be missed or still need to be clarified and defined into the new repo!!
  of course also check out the rfc first that was written on clanker side on that topic

  also on the roadmap for the storage system, we also want it to be able to plug into e.g. clanker easily as plugin. for example like sqlite can plugin easily

  the system will be written in zig!
