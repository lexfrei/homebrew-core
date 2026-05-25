class Bun < Formula
  desc "Incredibly fast JavaScript runtime, bundler, test runner, and package manager"
  homepage "https://bun.com/"
  # Need git checkout to build. Alternatively could set GIT_SHA if we extract the commit.
  url "https://github.com/oven-sh/bun.git",
      tag:      "bun-v1.3.14",
      revision: "0d9b296af33f2b851fcbf4df3e9ec89751734ba4"
  license all_of: [
    "MIT",
    "LGPL-2.0-or-later", # JavaScriptCore

    # Other libraries, https://github.com/oven-sh/bun/blob/main/LICENSE.md#linked-libraries
    # Ignoring ICU which is dynamically linked and reducing dual licenses to minimal set:
    "Apache-2.0",        # boringssl, simdutf, uSockets, highway, uWebsockets, Tigerbeetle
    "BSD-2-Clause",      # libarchive, libbase64, libspng
    "BSD-3-Clause",      # lol-html, libwebp, zstd
    "IJG",               # libjpeg-turbo
    "LGPL-2.1-or-later", # tinycc
    "Zlib",              # zlib-ng
    "Apache-2.0" => { with: "LLVM-exception" }, # __cxa_thread_atexit
  ]

  livecheck do
    url :stable
    regex(/^bun[._-]v?(\d+(?:\.\d+)+)$/i)
  end

  depends_on "cmake" => :build
  depends_on "llvm@21" => :build
  depends_on "ninja" => :build
  depends_on "rust" => :build

  uses_from_macos "perl" => :build # for webkit
  uses_from_macos "python" => :build # for webkit
  uses_from_macos "ruby" => :build # for webkit
  uses_from_macos "unzip" => :build

  on_linux do
    depends_on "lld@21" => :build
    depends_on "icu4c@78"
  end

  fails_with :gcc do
    version "10"
    cause "Needs C++20 features like std::span"
  end

  # Bootstrap with the same Bun version as upstream CI
  # https://github.com/oven-sh/bun/blob/bun-v#{version}/.buildkite/Dockerfile
  resource "bootstrap" do
    on_macos do
      on_arm do
        url "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-darwin-aarch64.zip"
        version "1.3.13"
        sha256 "5467e3f65dba526b9fea98f0cce04efafc0c63e169733ec27b876a3ad32da190"
      end
      on_intel do
        url "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-darwin-x64-baseline.zip"
        sha256 "a98ba6a480f22fda9b343626b906a4e26aa53618bf85d2bc5928ecf2ba45f0ed"
      end
    end
    on_linux do
      on_arm do
        url "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-linux-aarch64.zip"
        version "1.3.13"
        sha256 "70bae41b3908b0a120e1e58c5c8af30e74afae3b8d11b0d3fdd8e787ddfb4b22"
      end
      on_intel do
        url "https://github.com/oven-sh/bun/releases/download/bun-v1.3.13/bun-linux-x64-baseline.zip"
        sha256 "9d8a24292a7068090205daac0a5a223f5f69736f5287e37bf88d3b4031edc750"
      end
    end
  end

  # Performing a manual shallow git clone since a full clone of WebKit repo is ~18GB in size
  # and brew's unpack strategy will duplicate this forcing over 36GB disk space requirement
  # which can be insufficient for some runners. A shallow git clone is instead ~7GB.
  def fetch_webkit
    webkit_version = File.read("scripts/build/deps/webkit.ts")[/WEBKIT_VERSION = "(\h+)"/i, 1]
    odie "Unable to find WebKit version!" if webkit_version.blank?

    clone_args = %W[
      --branch=autobuild-#{webkit_version}
      --config=advice.detachedHead=false
      --config=core.fsmonitor=false
      --depth=1
    ]
    system "git", "clone", *clone_args, "https://github.com/oven-sh/WebKit.git", "vendor/WebKit"
  end

  # Based on https://github.com/oven-sh/bun/blob/main/CONTRIBUTING.md#building-webkit-locally--debug-mode-of-jsc
  def install
    bootstrap_version = File.read(".buildkite/Dockerfile")[/OLD_BUN_VERSION="v?(\d+(?:\.\d+)+)"/i, 1]
    odie "Update bootstrap to #{bootstrap_version}" if resource("bootstrap").version != bootstrap_version

    # Avoid `rustup` dependency by removing usage of nightly Rust features
    inreplace "scripts/build/deps/lolhtml.ts", "if (cfg.release && canBuildStdImmediateAbort)", "if (false)"

    if OS.linux?
      icu4c = deps.map(&:to_formula).find { |f| f.name.match?(/^icu4c@\d+$/) }
      ENV.append_path "C_INCLUDE_PATH", icu4c.opt_include
      ENV.append_path "CPLUS_INCLUDE_PATH", icu4c.opt_include

      # Needs actual clang++ on PATH. Not using compiler selection here to avoid
      # worst-case situation of having to install 3 different LLVM versions when
      # Bun and Rust both need versioned LLVM formulae but different versions.
      # Can reconsider if we add versioned LLVM support to compiler selection.
      ENV.prepend_path "PATH", Formula["llvm@21"].opt_bin
      ENV["CC"] = Formula["llvm@21"].opt_bin/"clang"
      ENV["CXX"] = Formula["llvm@21"].opt_bin/"clang++"
    end

    fetch_webkit
    resource("bootstrap").stage("bootstrap")
    ENV.prepend_path "PATH", buildpath/"bootstrap"

    args = ["--canary=off"]
    args << "--baseline=on" if Hardware::CPU.intel? && (build.bottle? || !Hardware::CPU.avx2?)

    system "bun", "run", "build:release:local", *args
    bin.install "build/release-local/bun"
    bin.install_symlink bin/"bun" => "bunx"

    bash_completion.install "completions/bun.bash" => "bun"
    fish_completion.install "completions/bun.fish"
    zsh_completion.install "completions/bun.zsh" => "_bun"
  end

  def caveats
    on_linux do
      on_intel do
        "Bun only runs on CPUs with SSE4.2 support (Nehalem or newer)"
      end
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/bun --version")
    refute_match "canary", shell_output("#{bin}/bun --revision")

    (testpath/"hello.ts").write <<~TYPESCRIPT
      console.log("hello", "bun");
    TYPESCRIPT
    assert_match "hello bun", shell_output("#{bin}/bun run hello.ts")
    assert_match "< hello bun >", shell_output("#{bin}/bunx cowsay hello bun")
  end
end
