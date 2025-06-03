# wasm-runner

Docker container that downloads a WASM compiled file and running using [wasmedge](https://github.com/WasmEdge/WasmEdge) runtime.

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
% docker run --rm -e WASM_URL=https://eyevinnlab-birme.minio-minio.auto.prod.osaas.io/code/main.wasm wasm-runner:local
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
