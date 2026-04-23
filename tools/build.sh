#!/usr/bin/env bash
#
# Build all the post articles into static html5
#
# Author: donkey <anjingyu_ws@foxmail.com>

readonly __VERSION__="0.1.9"

# Stop script on NZEC
# set -e
# Stop script if unbound variable found (use ${var:-} if intentional)
set -u
set -o pipefail
exec 3>&1

# Assume the terminal is a MODERN terminal
# support colorful output
normal="\e[0m"
black="\e[0;30m"
red="\e[0;31m"
green="\e[0;32m"
yellow="\e[0;33m"
blue="\e[0;34m"
magenta="\e[0;35m"
cyan="\e[0;36m"
white="\e[0;37m"

RUNNING="true"

function error()
{
    printf "%b\n" "[${red}E${normal}] $@" >&2
}

function warning()
{
    printf "%b\n" "[${yellow}W${normal}] $@" >&3
}

function info()
{
    printf "%b\n" "[${cyan}I${normal}] $@" >&3
}

function debug()
{
    printf "%b\n" "[${magenta}D${normal}] $@" >&3
}

function errtrap()
{
    error "[EXCEPTION:$1] Error: Command or function exited with status $?"
    RUNNING="false"
}

# Catch the exception
if command -v "trap" >/dev/null 2>&1; then
    # Get the exception information when program was breaked
    trap 'errtrap $LINENO' ERR
fi

function command_exists()
{
    command -v "$@" >/dev/null 2>&1
}

readonly CUR_DIR=$(cd $(dirname $0); pwd)
readonly PROJ_DIR=`dirname $CUR_DIR`
readonly MATHJAX_PATH="$CUR_DIR/mathjax/tex-mml-chtml.min.js"
readonly MATHJAX_FONT_DIR="$CUR_DIR/mathjax/output"

function check_required()
{
    if ! command_exists "pandoc"; then
        error "Please install ${green}pandoc${normal} first: ${yellow}sudo apt install ${green}pandoc${normal}"
        return 1
    fi
    return 0
}

# Encrypt a file with AES-128-CBC
#
# $1 - input file path
# $2 - output file path
# $3 - password
function encrypt()
{
    if ! command_exists "openssl"; then
        warning "The command ${yellow}openssl${normal} is required, please install it first."
        return
    fi

    openssl enc -aes-128-cbc -pbkdf2 -in $_FILE -out $_OUTPUT -pass pass:$_PASS
}

# Decrypt a file with AES-128-CBC
#
# $1 - input file path
# $2 - output file path
# $3 - password
function decrypt()
{
    if ! command_exists "openssl"; then
        warning "The command ${yellow}openssl${normal} is required, please install it first."
        return
    fi

    openssl enc -aes-128-cbc -pbkdf2 -d -in $_ENCRYPTED_FILE -out $_OUTPUT -pass pass:$_PASS
}

# Build one markdown or org file
#
# $1 - root input directory
# $2 - root output directory
# $3 - input file
# $4 - output directory
# $5 - theme directory
function build_one_file()
{
    local _ROOT_INPUT_DIR="$1"
    local _ROOT_OUTPUT_DIR="$2"
    local _INPUT_FILE="$3"
    local _OUTPUT_DIR="$4"
    local _THEME_DIR="$5"

    local _INPUT_FILE_BN=`basename $_INPUT_FILE`

    # Only support .md/markdown and .org
    if [[ "$_INPUT_FILE_BN" != *'.md' ]] && [[ "$_INPUT_FILE_BN" != *'.markdown' ]] && [[ "$_INPUT_FILE_BN" != *'.org' ]]; then
        return
    fi

    local _INPUT_DIR=`dirname $_INPUT_FILE`

    local _OUTPUT_FILE="$_OUTPUT_DIR/${_INPUT_FILE_BN%.*}.html"

    # Tricks for README.md or README.org
    local _INPUT_FILE_BNWE=${_INPUT_FILE_BN%.*}
    if [ $_INPUT_FILE_BNWE = "README" ]; then
        _OUTPUT_FILE="$_OUTPUT_DIR/index.html"
    fi

    if [ ! -f "$_THEME_DIR/styling.css" ]; then
        error "Required file missing: ${yellow}$_THEME_DIR/styling.css${normal}"
        exit 128
    fi

    if [ ! -d "$_OUTPUT_DIR" ]; then
        mkdir -p "$_OUTPUT_DIR"
    fi

    local declare _OPTS=("--css=/static/$(basename $_THEME_DIR)/styling.css" "--resource-path=.:${CUR_DIR}" "--mathjax=${CUR_DIR}/mathjax/tex-mml-chtml.min.js" "--to=html5")

    if [ -f "$_THEME_DIR/template.html" ]; then
        _OPTS+=("--template=$_THEME_DIR/template.html")
    fi

    pushd $_INPUT_DIR 1>/dev/null 2>&1
    if [[ "$_INPUT_FILE_BN" == *'.md' ]] || [[ "$_INPUT_FILE_BN" == *'.markdown' ]]; then
        # Extract the title from file content
        local _TITLE=$(sed -n "0,/#\s*.*$/ s/#\s*\(.*\)$/\1/p" $_INPUT_FILE)

        if [ -n "$_TITLE" ]; then
            # Append title
            _OPTS+=("--metadata" "title=$_TITLE")
        fi

        # Always use gfm
        _OPTS+=("--from=gfm")

        pandoc "${_OPTS[@]}" -o $_OUTPUT_FILE $_INPUT_FILE 1>/dev/null 2>&1

        if [ $? -eq 0 ]; then
            info "Generated ${green}$_INPUT_FILE_BN${normal}: ${cyan}$_TITLE${normal} ..."
        else
            error "Failed to generate ${red}$_INPUT_FILE_BN${normal} ..."
        fi
    elif [[ "$_INPUT_FILE_BN" == *'.org' ]]; then
        # Extract the title from file content
        local _TITLE=$(sed -n "0,/#+title:\s*.*$/ s/#+title:\s*\(.*\)$/\1/p" $_INPUT_FILE)

        if [ -n "$_TITLE" ]; then
            # Append title
            _OPTS+=("--metadata" "title=$_TITLE")
        fi

        pandoc "${_OPTS[@]}" -o $_OUTPUT_FILE $_INPUT_FILE 1>/dev/null 2>&1

        if [ $? -eq 0 ]; then
            info "Generated ${green}$_INPUT_FILE_BN${normal}: ${cyan}$_TITLE${normal} ..."
        else
            error "Failed to generate ${red}$_INPUT_FILE_BN${normal} ..."
        fi
    else
        case "$_INPUT_FILE_BN" in
            *'.png' | *'.jpg' | *'.jpeg' | *'.svg' | *'.webp' | *'.bmp')
                ;;
            *)
                warning "Unsupported format: ${red}${_INPUT_FILE_BN//*.}${normal}"
                ;;
        esac
    fi

    # Replace all the *.md or *.org to *.html
    local _URLS=$(sed -n 's/.*href="\([^"]*.*.\(md\|org\)\)".*/\1/p' $_OUTPUT_FILE | grep -v '^https\?://')
    if [ -n "$_URLS" ]; then
        echo "$_URLS" | while read -r _LINE; do
            local _U="$_LINE"
            # Use relative path in the link URL
            local _P="${_U%.*}.html"
            if [[ $(basename $_U) == 'README'* ]]; then
                _P="$(dirname $_U)/index.html"
            fi
            sed -i "s@href=\"$_U\"@href=\"$_P\"@g" "${_OUTPUT_FILE}"
        done
    fi

    popd 1>/dev/null 2>&1
}

# Build one directory recursively and keep the hierarchy structure.
#
# $1 - root input directory
# $2 - root output directory
# $3 - input directory
# $4 - output directory
# $5 - theme directory
function build_one_dir()
{
    local _ROOT_INPUT_DIR="$1"
    local _ROOT_OUTPUT_DIR="$2"
    local _INPUT_DIR="$3"
    local _OUTPUT_DIR="$4"
    local _THEME_DIR="$CUR_DIR/themes/github"

    if [ $# -gt 4 ]; then
        _THEME_DIR="$5"
        if [ ! -d "$_THEME_DIR" ]; then
            warning "${yellow}$5${normal} is not a valid theme, use default theme ${yellow}github${normal}."
            _THEME_DIR="$CUR_DIR/themes/github"
        fi
    fi

    if [ ! -d "$_THEME_DIR" ]; then
        error "${yellow}$(basename $_THEME_DIR)${normal} is not a valid theme."
        exit -1
    fi

    for fd in `ls -1 "$_INPUT_DIR/"`; do
        local _FPATH="$_INPUT_DIR/$fd"
        if [ -f "$_FPATH" ]; then
            build_one_file "$_ROOT_INPUT_DIR" "$_ROOT_OUTPUT_DIR" "$_INPUT_DIR/$fd" "$_OUTPUT_DIR" "$_THEME_DIR"
        elif [ -d "$_FPATH" ]; then
            build_one_dir "$_ROOT_INPUT_DIR" "$_ROOT_OUTPUT_DIR" "$_INPUT_DIR/$fd" "$_OUTPUT_DIR/$fd" "$_THEME_DIR"
        fi
    done
}

# Publish one file
#
# $1 - input file path
# $2 - output file path
function publish_one_file()
{
    local _INPUT_FILE="$1"
    local _OUTPUT_FILE="$2"
    local _OUTPUT_DIR=`dirname $_OUTPUT_FILE`

    if [ ! -d "$_OUTPUT_DIR" ]; then
        mkdir -p "$_OUTPUT_DIR"
    fi

    info "Publishing the file: ${yellow}`basename $_INPUT_FILE`${normal} ..."
    cp -f "$_INPUT_FILE" "$_OUTPUT_DIR"
}

# Publish one directory recursively and keep the hierarchy structure
#
# $1 - input directory
# $2 - output directory
function publish_one_dir()
{
    local _INPUT_DIR="$1"
    local _OUTPUT_DIR="$2"

    for fd in `ls -1 "$_INPUT_DIR/"`; do
        local _FPATH="$_INPUT_DIR/$fd"
        if [ -f "$_FPATH" ]; then
            publish_one_file "$_INPUT_DIR/$fd" "$_OUTPUT_DIR/$fd"
        elif [ -d "$_FPATH" ]; then
            publish_one_dir "$_INPUT_DIR/$fd" "$_OUTPUT_DIR/$fd"
        fi
    done
}

function help()
{
    echo "Usage: `basename $0` [-h,--help] [-v,--version] [-i,--input DIR] [-o,--output DIR] [-t,--theme THEME]"
    echo
    echo -e "Build the ${green}markdown${normal} or ${green}org${normal} files to ${yellow}html5${normal} with my own style."
    echo
    echo "Options:"
    echo -e "    ${green}-h${normal},${green}--help${normal}         Show help and exit"
    echo -e "    ${green}-v${normal},${green}--version ${normal}     Show version and exit"
    echo -e "    ${green}-i${normal},${green}--input${yellow} DIR${normal}    Specify a input DIR, default: \$PROJECT/posts"
    echo -e "    ${green}-o${normal},${green}--output${yellow} DIR${normal}   Specify the output DIR, default: \$PROJECT/output"
    echo -e "    ${green}-t${normal},${green}--theme${yellow} THEME${normal}  Specify the theme, default: github"
    echo -e "    ${green}-p${normal},${green}--publish${yellow} DIR${normal}  Specify the publish directory"
    echo
    echo "Examples:"
    echo -e "    # Build all the files in ${green}posts${normal}, and output to the directory ${yellow}output${normal}"
    echo "    tools/`basename $0` -i posts -o output"
    echo
}

function main()
{
    if ! check_required; then
        exit 1
    fi

    local _ARTICLES_DIR="$PROJ_DIR/notes"
    local _OUTPUT_DIR="$PROJ_DIR/docs"
    local _THEME="github"
    local _PUBLISH_DIR=""
    local _OPTS=""

    while [ $# -ne 0 ]; do
        case "$1" in
            -i|--input)
                shift
                _ARTICLES_DIR=`realpath "$1"`
                ;;
            -o|--output)
                shift
                _OUTPUT_DIR=`realpath "$1"`
                ;;
            -t|--theme)
                shift
                _THEME="$1"
                ;;
            -p|--publish)
                shift
                _PUBLISH_DIR="$1"
                ;;
            --toc)
                _OPTS="--toc --toc-depth=2"
                ;;
            -v|--version)
                echo "$__VERSION__"
                exit 0
                ;;
            -h|--help)
                help
                exit 0
                ;;
            *)
                ;;
        esac
        shift
    done

    if [ ! -d "$_ARTICLES_DIR" ]; then
        error "${yellow}$_ARTICLES_DIR${normal} is not a valid directory."
        exit -1
    fi

    if [ ! -d "$_OUTPUT_DIR" ]; then
        mkdir -p "$_OUTPUT_DIR"

        _OUTPUT_DIR=`realpath "$_OUTPUT_DIR"`
    fi

    build_one_dir "$_ARTICLES_DIR" "$_OUTPUT_DIR" "$_ARTICLES_DIR" "$_OUTPUT_DIR" "$CUR_DIR/themes/$_THEME" $_OPTS

    if [ -d "$MATHJAX_FONT_DIR" ]; then
        info "Copying the fonts required by ${green}MathJax${normal} ..."
        cp -rf "$MATHJAX_FONT_DIR" "$_OUTPUT_DIR"
    fi

    if [ ! -d "$_OUTPUT_DIR/static/$_THEME" ]; then
        info "Copying the style sheet required by ${green}github theme${normal} ..."
        mkdir -p "$_OUTPUT_DIR/static/$_THEME"
        cp -rf "$CUR_DIR/themes/$_THEME/styling.css" "$_OUTPUT_DIR/static/$_THEME"
    fi

    # Do publish if specify this argument
    if [ -n "$_PUBLISH_DIR" ]; then
        publish_one_dir "$_OUTPUT_DIR" "$_PUBLISH_DIR"
    fi
}

main "$@"
