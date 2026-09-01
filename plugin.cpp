#if defined(__APPLE__)
// The plugin uses the host evaluator's libc++ rather than linking a second
// C++ runtime. Keep the standard-library ABI at Apple's stable ABI-1 even
// when the build environment supplies newer nixpkgs libc++ headers.
#undef _LIBCPP_ABI_VERSION
#define _LIBCPP_ABI_VERSION 1
#endif

#define VERSION_ENCODE(major, minor, patch)                                    \
  ((major) * 10000 + (minor) * 100 + (patch))
#define NIX_VERSION_NUM                                                        \
  VERSION_ENCODE(NIX_MAJOR_VERSION, NIX_MINOR_VERSION, NIX_PATCH_VERSION)
#define NIX_VERSION_LE(major, minor, patch)                                    \
  (NIX_VERSION_NUM <= VERSION_ENCODE(major, minor, patch))
#define NIX_VERSION_GE(major, minor, patch)                                    \
  (NIX_VERSION_NUM >= VERSION_ENCODE(major, minor, patch))

#if NIX_VERSION_LE(2, 24, 99)
#include <eval.hh>
#include <primops.hh>
#else
#include <nix/expr/eval.hh>
#include <nix/expr/primops.hh>
#endif

#include <format>
#include <string>
#include <vector>

using namespace nix;

#if defined(__APPLE__)
// Newer libc++ headers can leave these basic_string members as external
// references, while the active Darwin evaluator's system libc++ keeps them
// inline. Emit the compatibility methods in the plugin so no second libc++
// dylib is needed at runtime.
template class std::basic_string<char>;
#endif

extern "C" {
char *nix_rage_decrypt(const char **identities, const size_t *identity_sizes,
                       size_t identity_count, const char *encrypted,
                       size_t encrypted_size, const char *cache_key,
                       bool cache);
char *nix_rage_decrypt_error();
}

char *decrypt_content(EvalState &state, const PosIdx pos, Value **args) {
  state.forceList(
      *args[0], pos,
      "while evaluating the first argument passed to 'builtins.importAge'");
  state.forceValue(*args[1], pos);
  state.forceAttrs(
      *args[2], pos,
      "while evaluating the first argument passed to 'builtins.importAge'");

  if (args[1]->type() != nPath) {
    state
        .error<TypeError>("value is %1% while a path was expected",
                          showType(*args[1]))
        .atPos(pos)
        .debugThrow();
  }

  auto cache_value = args[2]->attrs()->get(state.symbols.create("cache"));
  bool cache = true;
  if (cache_value) {
    cache = cache_value->value->boolean();
  }

  std::string encrypted;
  std::string cache_key;
#if NIX_VERSION_GE(2, 30, 00)
  auto encrypted_path = args[1]->path();
  encrypted = encrypted_path.readFile();
  cache_key = encrypted_path.to_string();
#else
  auto filename = args[1]->payload.path.path;
  encrypted = readFile(Path(filename));
  cache_key = filename;
#endif

  std::vector<std::string> identity_contents;
  identity_contents.reserve(args[0]->listSize());
#if NIX_VERSION_GE(2, 30, 00)
  for (auto elem : args[0]->listView()) {
#else
  for (auto elem : args[0]->listItems()) {
#endif
    state.forceValue(*elem, pos);
    if (elem->type() != nPath) {
      state
          .error<TypeError>("value is %1% while a path was expected",
                            showType(*elem))
          .atPos(pos)
          .debugThrow();
    }
#if NIX_VERSION_GE(2, 30, 00)
    identity_contents.push_back(elem->path().readFile());
#else
    identity_contents.push_back(readFile(Path(elem->payload.path.path)));
#endif
  }

  std::vector<const char *> identities;
  std::vector<size_t> identity_sizes;
  identities.reserve(identity_contents.size());
  identity_sizes.reserve(identity_contents.size());
  for (const auto &identity : identity_contents) {
    identities.push_back(identity.data());
    identity_sizes.push_back(identity.size());
  }

  auto content = nix_rage_decrypt(identities.data(), identity_sizes.data(),
                                  identities.size(), encrypted.data(),
                                  encrypted.size(), cache_key.c_str(), cache);
  if (!content) {
    auto err = nix_rage_decrypt_error();
    if (!err) {
      throw Error("decrypt error while evaluation: unknown error");
    } else {
      throw Error(std::format("decrypt error while evaluation: {}", err));
    }
  };

  return content;
}

static nix::PrimOp make_primop(const char *name,
                               std::initializer_list<std::string> args,
                               const char *doc, nix::PrimOpFun *impl) {
#if NIX_VERSION_GE(2, 34, 00)
  nix::PrimOp primop{
      .name = name,
      .args = args,
      .arity = args.size(),
      .doc = doc,
      .addTrace = true,
      .impl = impl,
      .experimentalFeature = {},
      .internal = false,
  };
#else
  nix::PrimOp primop{
      .name = name,
      .args = args,
      .arity = args.size(),
      .doc = doc,
      .fun = impl,
      .experimentalFeature = {},
  };
#endif
  return primop;
}

void prim_importAge(EvalState &state, const PosIdx pos, Value **args,
                    Value &v) {
  auto content = decrypt_content(state, pos, args);
  if (!content) {
    throw Error("decrypt error while evaluation");
  };

  Expr *parsed;
  try {
    parsed = state.parseExprFromString(std::move(content),
                                       state.rootPath(CanonPath::root));
  } catch (Error &e) {
    e.addTrace(state.positions[pos],
               "while parsing the output from 'builtins.importAge'");
    throw;
  }
  try {
    state.eval(parsed, v);
  } catch (Error &e) {
    e.addTrace(state.positions[pos],
               "while evaluating the output from 'builtins.importAge'");
    throw;
  }
}

void prim_readAgeFile(EvalState &state, const PosIdx pos, Value **args,
                      Value &v) {
  auto content = decrypt_content(state, pos, args);
  if (!content) {
    throw Error("decrypt error while evaluation");
  };
#if NIX_VERSION_GE(2, 34, 00)
  v.mkString(content, state.mem);
#else
  v.mkString(content);
#endif
}

static std::vector<RegisterPrimOp> primops = std::vector{
    nix::RegisterPrimOp(
        make_primop("importAge", {"identities", "path", "configs"},
                    "Import encypted .nix file", prim_importAge)),
    nix::RegisterPrimOp(make_primop("readAgeFile",
                                    {"identities", "path", "configs"},
                                    "Read encrypted file", prim_readAgeFile)),
};
