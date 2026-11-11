set quiet

root := justfile_directory()

[windows]
set shell := ["pwsh", "-NoLogo", "-Command"]

[private]
@default:
  @just --list

[unix]
@build:
  cd {{root}} && tools/build.sh

[windows]
@build:
  cd {{root}} && tools/build.ps1

@test:
  cd {{root}}/docs && miniserve -p 8998 .

[unix]
@clean:
  cd {{root}} && rm -rf docs

[windows]
@clean:
  cd {{root}} && Remove-Item -Force -Recurse docs
