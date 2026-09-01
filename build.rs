// Source: https://github.com/lf-/nix-doc/blob/55599ec502e01e96673cbfcd2940b9dc1d392ec5/plugin/build.rs#L5C1-L27C2
trait AddPkg {
    fn add_pkg_config(&mut self, pkg: pkg_config::Library) -> &mut Self;
}
impl AddPkg for cc::Build {
    fn add_pkg_config(&mut self, pkg: pkg_config::Library) -> &mut Self {
        for p in pkg.include_paths.into_iter() {
            self.include(p);
        }
        self
    }
}

struct NixVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: Option<u64>,
    pub pre: Option<String>,
}

impl NixVersion {
    fn from_str(version: &str) -> anyhow::Result<Self> {
        let re = regex::Regex::new(r"(\d+).(\d+)(.(\d+)|)(pre(.+)|)$")?;
        let caps = re
            .captures(version)
            .ok_or(anyhow::anyhow!("Fail to parse nix version!"))?;
        let major = caps.get(1).unwrap().as_str().parse().unwrap();
        let minor = caps.get(2).unwrap().as_str().parse().unwrap();
        let patch = caps.get(4).map(|x| x.as_str().parse().unwrap());
        let pre = caps.get(6).map(|x| x.as_str().to_string());
        Ok(Self {
            major,
            minor,
            patch,
            pre,
        })
    }
}

impl std::fmt::Display for NixVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}.{}{}{}",
            self.major,
            self.minor,
            self.patch.map(|x| format!(".{x}")).unwrap_or_default(),
            self.pre
                .as_ref()
                .map(|x| format!("pre{x}"))
                .unwrap_or_default()
        )
    }
}

fn main() {
    // Nix plugins are loaded into an already-running Nix process.  pkg-config
    // is used only to discover headers and the API version: forwarding its
    // link metadata would make the plugin own a second libnix runtime on
    // Darwin, and can also affect Cargo's final cdylib link step.
    let nix_expr = pkg_config::Config::new()
        .cargo_metadata(false)
        .atleast_version("2.24")
        .probe("nix-expr")
        .unwrap();
    let nix_store = pkg_config::Config::new()
        .cargo_metadata(false)
        .atleast_version("2.24")
        .probe("nix-store")
        .unwrap();

    if let Ok(expected) = std::env::var("NIX_RAGE_EXPECTED_NIX_VERSION") {
        let actual = nix_expr.version.split('+').next().unwrap();
        assert_eq!(
            actual, expected,
            "nix-rage host bootstrap refuses development headers for Nix {actual}; \
             the running evaluator and declared host provenance are {expected}"
        );
    }

    let nix_ver = NixVersion::from_str(&nix_expr.version).unwrap();
    let nix_major_ver = nix_ver.major.to_string();
    let nix_minor_ver = nix_ver.minor.to_string();
    let nix_patch_ver = nix_ver.patch.unwrap_or_default().to_string();

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // The C++ object is linked into Cargo's final cdylib. Allow its Nix
        // references to resolve from the process that dlopen()s the plugin.
        println!("cargo::rustc-cdylib-link-arg=-Wl,-undefined,dynamic_lookup");
    }

    println!("cargo::rerun-if-changed=plugin.cpp");
    let mut cpp = cc::Build::new();
    cpp.file("plugin.cpp")
        .cpp(true)
        // The host evaluator already owns libc++; linking the nixpkgs copy
        // into the plugin creates the same kind of runtime identity split as
        // linking libnix itself.
        .cpp_link_stdlib(None)
        .opt_level(2)
        .shared_flag(true)
        .std("c++23")
        .add_pkg_config(nix_expr)
        .add_pkg_config(nix_store)
        .define("NIX_MAJOR_VERSION", Some(nix_major_ver).as_deref())
        .define("NIX_MINOR_VERSION", Some(nix_minor_ver).as_deref())
        .define("NIX_PATCH_VERSION", Some(nix_patch_ver).as_deref())
        .define("NIX_VERSION", Some(nix_ver.to_string()).as_deref())
        // Emit only cc's own archive metadata so the C++ registration object
        // is linked into the cdylib; pkg-config's Nix metadata is disabled at
        // each probe above.
        .cargo_metadata(true)
        // Keep the C++ registration object in the Rust cdylib. This does not
        // add Nix libraries because both pkg-config and cc Cargo metadata are
        // disabled above.
        .link_lib_modifier("+whole-archive");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // Apple libc++ uses the stable ABI-1 layout. Newer nixpkgs libc++
        // headers otherwise emit calls to internals absent from the host's
        // /usr/lib/libc++, causing a plugin crash despite host-resolved Nix
        // symbols.
        cpp.define("_LIBCPP_ABI_VERSION", Some("1"));
        // Nix's stdenv may append its libc++ configuration macro after the
        // normal cc-rs defines. Override that final command-line value too.
        cpp.flag("-U_LIBCPP_ABI_VERSION");
        cpp.flag("-D_LIBCPP_ABI_VERSION=1");
        if let Ok(flags) = std::env::var("NIX_CFLAGS_COMPILE") {
            let flags = flags
                .split_whitespace()
                .filter(|flag| !flag.starts_with("-D_LIBCPP_ABI_VERSION="))
                .collect::<Vec<_>>()
                .join(" ");
            std::env::set_var("NIX_CFLAGS_COMPILE", flags);
        }
    }
    cpp.compile("plugin");
}
