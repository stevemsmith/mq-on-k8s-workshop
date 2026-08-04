# poison-consumer

`amqspoison.c` simulates a consumer that can never process a message: it
repeatedly `MQGET`s the same message under syncpoint and calls `MQBACK`
to roll the get back, so the queue manager's automatic poison-message
handling (`BOTHRESH`/`BOQNAME`) eventually reroutes the message to the
backout queue.

Built by `../build-poison-consumer.sh` into `amqspoisonc`, which
`../Dockerfile` copies into the final `moov-mq:local` image. See the
"Poison messages and the dead-letter queue" section of the top-level
README for how it's used.

This `README.md` file exists so the `COPY README.md MQINST*/*.tar.gz`
line in `Dockerfile` always has at least one real match, even before
`build-poison-consumer.sh` has staged the arm64 archive into `MQINST/`.
