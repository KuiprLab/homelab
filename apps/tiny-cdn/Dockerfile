FROM rust:1-slim-bookworm AS builder

# rust-toolchain.toml pins nightly; the crate only needs edition 2024 (stable 1.85+).
ENV RUSTUP_TOOLCHAIN=stable
WORKDIR /build

# Build dependencies against a stub so they survive source changes.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
    && echo 'fn main() {}' > src/main.rs \
    && cargo build --release --locked \
    && rm -rf src

COPY src ./src
RUN touch src/main.rs && cargo build --release --locked

FROM debian:bookworm-slim

RUN useradd --system --uid 10001 --home /data --shell /usr/sbin/nologin tiny-cdn \
    && mkdir -p /data \
    && chown tiny-cdn:tiny-cdn /data

COPY --from=builder /build/target/release/tiny-cdn /usr/local/bin/tiny-cdn

USER tiny-cdn
WORKDIR /data
VOLUME ["/data"]
EXPOSE 3030

ENTRYPOINT ["tiny-cdn"]
CMD ["--bind", "0.0.0.0", "--port", "3030", "-s", "/data", "-p", "/data/authorized.pub"]
