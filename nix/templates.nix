# The template catalog and archives the Worker reads from its
# `TEMPLATES_BUCKET` (`template_catalog.json` plus one `<name>.zip` per
# template), built the way upstream's `deploy_templates.sh` does minus the
# network-bound lockfile sync and the upload.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
}:
stdenvNoCC.mkDerivation {
  pname = "vibesdk-templates";
  version = "0-unstable-2026-05-13";

  src = fetchFromGitHub {
    owner = "cloudflare";
    repo = "vibesdk-templates";
    rev = "7ea201fafdef44f5dcc5bc05f03b36e3198cebe5";
    hash = "sha256-rBTQf2l+KYaJdU5Cqb2drAzPB80TwoL00YkJf+bH7Ko=";
  };

  nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) ];

  buildPhase = ''
    runHook preBuild
    python3 tools/generate_templates.py --clean
    python3 generate_template_catalog.py --output template_catalog.json
    mkdir zips
    for dir in build/*/; do
      name=$(basename "$dir")
      if [ -f "$dir/package.json" ] && [ -d "$dir/prompts" ] \
        && { [ -f "$dir/wrangler.jsonc" ] || [ -f "$dir/wrangler.toml" ]; }; then
        python3 create_zip.py "$dir" "zips/$name.zip"
      fi
    done
    runHook postBuild
  '';

  # Guard: the Worker fails every template lookup when the catalog names an
  # archive that was not built.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp template_catalog.json "$out/"
    cp zips/*.zip "$out/"
    python3 - <<'EOF'
    import json, os, sys
    out = os.environ["out"]
    names = [t["name"] for t in json.load(open(f"{out}/template_catalog.json"))]
    missing = [n for n in names if not os.path.exists(f"{out}/{n}.zip")]
    if not names or missing:
        sys.exit(f"vibesdk-templates: catalog {names} lacks archives {missing}")
    EOF
    runHook postInstall
  '';

  meta = {
    description = "VibeSDK template catalog and archives for the local templates bucket";
    homepage = "https://github.com/cloudflare/vibesdk-templates";
    platforms = lib.platforms.all;
  };
}
