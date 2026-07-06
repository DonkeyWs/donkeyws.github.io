root := justfile_directory()

[private]
@default:
  @just --list

@build:
  cd {{root}} && tools/build.sh

@test:
  cd {{root}}/docs && miniserve -p 8998 .

@clean:
  cd {{root}} && rm -rf docs
