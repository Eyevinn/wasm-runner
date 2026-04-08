# wasm-runner

Docker container that downloads a WASM compiled file and running using [wasmedge](https://github.com/WasmEdge/WasmEdge) runtime. Available as an open web service in [Eyevinn Open Source Cloud](https://docs.osaas.io/osaas.wiki/Service%3A-WASM-Runner.html).

---
<div align="center">

## Quick Demo: Open Source Cloud

Run this service in the cloud with a single click.

[![Badge OSC](https://img.shields.io/badge/Try%20it%20out!-1E3A8A?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMTIiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyKSIvPgo8Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSI3IiBzdHJva2U9ImJsYWNrIiBzdHJva2Utd2lkdGg9IjIiLz4KPGRlZnM+CjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQwX2xpbmVhcl8yODIxXzMxNjcyIiB4MT0iMTIiIHkxPSIwIiB4Mj0iMTIiIHkyPSIyNCIgZ3JhZGllbnRVbml0cz0idXNlclNwYWNlT25Vc2UiPgo8c3RvcCBzdG9wLWNvbG9yPSIjQzE4M0ZGIi8+CjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzREQzlGRiIvPgo8L2xpbmVhckdyYWRpZW50Pgo8L2RlZnM+Cjwvc3ZnPgo=)](https://app.osaas.io/browse/eyevinn-wasm-runner)

</div>

---

## Usage

Build container image:

```
% docker build -t wasm-runner:local .
```

Create a sample application (example in Rust)

```rust
fn main() {
  println!("Hello, world!");
}
```

Compile to wasm:

```
% rustup target add wasm32-wasip1
% rustc main.rs --target wasm32-wasip1
```

Upload `main.wasm` to a bucket for download and then run the container providing the URL to the WASM file:

```
% docker run --rm \
  -p 8080:8080 \
  -e WASM_URL=https://eyevinnlab-birme.minio-minio.auto.prod.osaas.io/code/main.wasm \
  wasm-runner:local
```

Alternatively, provide a GitHub repository URL containing a `.wasm` file:

```
% docker run --rm \
  -p 8080:8080 \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  wasm-runner:local
```

For private repositories, provide a GitHub personal access token:

```
% docker run --rm \
  -p 8080:8080 \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -e GITHUB_TOKEN=<token> \
  wasm-runner:local
```

You can specify a branch using a URL fragment:

```
% docker run --rm \
  -p 8080:8080 \
  -e GITHUB_URL=https://github.com/<org>/<repo>#<branch> \
  wasm-runner:local
```

The entrypoint will clone the repository, find the first `.wasm` file, and run it. The WASM module is expected to follow the [WASI](https://wasi.dev/) convention and export a `_start` entry point (the default for `wasmedge`).

The WASM application `main.wasm` can now be invoked through the HTTP server on port 8080. Provides these endpoints:

| Method | Path | Description |
| ------ | ---- | ----------- |
| GET    | /    | Invoke the application and return what the application writes to STDOUT |
| POST   | /    | Invoke the application and the request body is provided to the application on STDIN. Return STDOUT output |

```
% curl http://localhost:8080/
Hello, world!
```

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md)

## License

This project is licensed under the MIT License, see [LICENSE](LICENSE).

# Support

Join our [community on Slack](http://slack.streamingtech.se) where you can post any questions regarding any of our open source projects. Eyevinn's consulting business can also offer you:

- Further development of this component
- Customization and integration of this component into your platform
- Support and maintenance agreement

Contact [sales@eyevinn.se](mailto:sales@eyevinn.se) if you are interested.

# About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinntechnology.se) is an independent consultant firm specialized in video and streaming. Independent in a way that we are not commercially tied to any platform or technology vendor. As our way to innovate and push the industry forward we develop proof-of-concepts and tools. The things we learn and the code we write we share with the industry in [blogs](https://dev.to/video) and by open sourcing the code we have written.

Want to know more about Eyevinn and how it is to work here. Contact us at work@eyevinn.se!
