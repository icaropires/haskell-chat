FROM mitchty/alpine-ghc as builder

LABEL description="Builder for haskell TCP chat server" repositoy="https://github.com/icaropires/haskell-chat"

WORKDIR /app

RUN set +x \
  && apk update \
  && apk add --no-cache build-base \
  && cabal update \
  && cabal install network-2.6.3.2 stm async \
  && rm -rf /var/cache/apk/*

COPY src/server.hs src/server.hs

RUN ghc -o server --make src/server.hs


FROM alpine:3.9

LABEL description="Run haskell TCP chat server"

WORKDIR /app/
COPY --from=builder /app/server /app/server

RUN set +x \
  && apk update \
  && apk add --no-cache gmp \
  && rm -rf /var/cache/apk/*

EXPOSE 8000

ENTRYPOINT ["/app/server"]
CMD ["8000"]
