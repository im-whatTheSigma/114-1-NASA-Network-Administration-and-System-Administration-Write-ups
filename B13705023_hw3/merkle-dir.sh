#!/bin/bash
# set -x

# get rid of space
usage='merkle-dir.sh - A tool for working with Merkle trees of directories.

Usage:
  merkle-dir.sh <subcommand> [options] [<argument>]
  merkle-dir.sh build <directory> --output <merkle-tree-file>
  merkle-dir.sh gen-proof <path-to-leaf-file> --tree <merkle-tree-file> --output <proof-file>
  merkle-dir.sh verify-proof <path-to-leaf-file> --proof <proof-file> --root <root-hash>

Subcommands:
  build          Construct a Merkle tree from a directory (requires --output).
  gen-proof      Generate a proof for a specific file in the Merkle tree (requires --tree and --output).
  verify-proof   Verify a proof against a Merkle root (requires --proof and --root).

Options:
  -h, --help     Show this help message and exit.
  --output FILE  Specify an output file (required for build and gen-proof).
  --tree FILE    Specify the Merkle tree file (required for gen-proof).
  --proof FILE   Specify the proof file (required for verify-proof).
  --root HASH    Specify the expected Merkle root hash (required for verify-proof).

Examples:
  merkle-dir.sh build dir1 --output dir1.mktree
  merkle-dir.sh gen-proof file1.txt --tree dir1.mktree --output file1.proof
  merkle-dir.sh verify-proof dir1/file1.txt --proof file1.proof --root abc123def456' #inline quotes to avoid space

# no args
if [ "$#" -eq 0 ]; then
    echo "$usage";
    exit 1;
fi 

# single -h/--help
if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
    echo "$usage";
    exit 0
fi

# -h/--help present with other args -> error
for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        echo "$usage";
        exit 1
    fi
done

subcmd="$1"
shift || true

options=()
args=()

# parse args/options (require value for known long options)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output|--tree|--proof|--root)
            if [ "$#" -lt 2 ] || [[ "$2" == --* ]]; then
                echo "$usage";
                exit 1
            fi
            options+=("$1" "$2")
            shift 2
            ;;
        -*)
            echo "$usage";
            exit 1
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

#helrper
canwrite() {
    # returns 0 if path is canwrite (file can be created or overwritten)

    if [[ -L "$1" || -d "$1" ]]; then
        return 1 # func is return not exit
    fi
    if [[ ! -e "$1" || ( -f "$1" && -w "$1" ) ]]; then
        return 0
    fi
    return 1
}

# ---------- build implementation ----------
case "$subcmd" in
    build)
        if [ "${#args[@]}" -ne 1 ]; then
            echo "$usage";
            exit 1
        fi

        dir="${args[0]}"
        # reject symlinks and non-directories 
        if [[ ! -d "$dir" || -L "$dir" ]]; then
            echo "$usage";
            exit 1
        fi
        if [[ "${#options[@]}" -ne 2 || "${options[0]}" != "--output" || ( -e "${options[1]}" && ! -f "${options[1]}" ) ]]; then
            echo "$usage";
            exit 1
        fi

    out="${options[1]}"
        if ! canwrite "$out"; then
            echo "$usage";
            exit 1
        fi

        # collect files (sorted)
    mapfile -t file_list < <(LC_COLLATE=C find "$dir" -type f | LC_COLLATE=C sort)

        # print relative paths (use realpath --relative-to to match sample behavior)
        if command -v realpath >/dev/null 2>&1; then
            printf "%s\n" "$(realpath -s --relative-to="$dir" "${file_list[@]}")" >"$out"
        else
            # fall back to printing paths relative to $dir using parameter expansion
            for f in "${file_list[@]}"; do
                rel="${f#$"dir/"}"
                printf '%s\n' "$rel" >>"$out"
            done
        fi

        printf '\n' >>"$out"

        # compute level-0 hashes (file hashes)
        level0=()
        for file in "${file_list[@]}"; do
            h="$(sha256sum "$file" | awk '{print $1}')"
            level0+=("$h")
        done

        # validate leaf hashes are valid 64-char hex strings; fail early if any file hash is missing/invalid
        for idx in "${!level0[@]}"; do
            v="${level0[$idx]}"
            if [[ ! "$v" =~ ^[A-Fa-f0-9]{64}$ ]]; then
                echo "sha256sum failed or produced invalid hash for file: ${file_list[$idx]}" >&2
                exit 1
            fi
        done

        # print level 0 (colon-separated)
        for idx in "${!level0[@]}"; do
            if [[ $idx -eq 0 ]]; then
                printf "%s" "${level0[$idx]}" >>"$out"
            else
                printf ":%s" "${level0[$idx]}" >>"$out"
            fi
        done
        printf "\n" >>"$out"

        # build upper levels by pairing
        while [[ ${#level0[@]} -gt 1 ]]; do
            next_level=()
            level_line=""
            idx=0
            while (( idx < ${#level0[@]} )); do
                jdx=$((idx + 1))
                if (( jdx < ${#level0[@]} )); then
                    concat_hex="${level0[$idx]}${level0[$jdx]}"
                    node_hash="$(printf '%s' "$concat_hex" | xxd -r -p | sha256sum | awk '{print $1}')"
                    if [ -n "$level_line" ]; then
                        level_line+=":"
                    fi
                    level_line+="$node_hash"
                    next_level+=("$node_hash")
                else
                    # carry odd leftover
                    next_level+=("${level0[$idx]}")
                fi
                idx=$((idx + 2))
            done
            printf "%s\n" "$level_line" >>"$out"
            level0=("${next_level[@]}")
        done

        exit 0
        ;;

    # ---------- gen-proof ----------
    gen-proof)
        # parse args (expected single path argument plus options)
        if [ "${#args[@]}" -ne 1 ]; then
            echo "$usage";
            exit 1;
        fi
        if [ "${#options[@]}" -ne 4 ]; then
            echo "$usage";
            exit 1;
        fi

        # normalize options order (--tree and --output in any order)
        if [ "${options[0]}" == "--tree" ] && [ "${options[2]}" == "--output" ]; then
            tree_file="${options[1]}"
            output_file="${options[3]}"
        elif [ "${options[0]}" == "--output" ] && [ "${options[2]}" == "--tree" ]; then
            output_file="${options[1]}"
            tree_file="${options[3]}"
        else
            echo "$usage";
            exit 1
        fi

        if [[ ! -f "$tree_file" || -L "$tree_file" ]]; then
            echo "$usage";
            exit 1
        fi
        if [[ -e "$output_file" && ! -f "$output_file" ]] || [[ -L "$output_file" ]]; then
            echo "$usage";
            exit 1
        fi

        build_proof() {
            target="$1"
            tfile="$2"
            phase=0   # 0 = reading files list, 1 = processing levels
            idx=0
            leftover_val=""

            while IFS= read -r ln || [ -n "$ln" ]; do
                if [ -z "$ln" ]; then
                    phase=1
                    if [ -z "${target_pos+x}" ]; then
                        return 1
                    fi
                    printf "leaf_index:%s,tree_size:%s\n" "$((target_pos + 1))" "$idx"
                    continue
                fi

                if [ $phase -eq 0 ]; then
                    if [ "$ln" = "$target" ]; then
                        target_pos=$idx
                    fi
                    idx=$((idx + 1))
                else
                    IFS=":" read -r -a node_list <<<"$ln"
                    if [ -n "$leftover_val" ]; then
                        node_list+=("$leftover_val")
                    fi
                    # print sibling if exists
                    if [ $idx -gt 1 ] && [ $((target_pos ^ 1)) -lt $idx ]; then
                        echo "${node_list[$((target_pos ^ 1))]}"
                    fi
                    # compute leftover for next round
                    if [ $((idx % 2)) -gt 0 ]; then
                        leftover_val="${node_list[$((idx - 1))]}"
                    else
                        leftover_val=
                    fi
                    idx=$(((idx + 1) / 2))
                    target_pos=$((target_pos / 2))
                fi
            done <"$tfile"
            return 0
        }

        if ! build_proof "${args[0]}" "$tree_file" > "$output_file"; then
            exit 1
        else
            exit 0
        fi
        ;;

    # ---------- verify-proof ----------
    verify-proof)
        if [ "${#args[@]}" -ne 1 ] || [ ! -f "${args[0]}" ]; then
            echo "$usage";
            exit 1
        fi
        if [ "${#options[@]}" -ne 4 ]; then
            echo "$usage";
            exit 1
        fi

        # normalize options
        if [ "${options[0]}" == "--proof" ] && [ "${options[2]}" == "--root" ]; then
            proof="${options[1]}"
            root="${options[3]}"
        elif [ "${options[0]}" == "--root" ] && [ "${options[2]}" == "--proof" ]; then
            root="${options[1]}"
            proof="${options[3]}"
        else
            echo "$usage";
            exit 1
        fi

        if [[ ! -f "$proof" || ! -f "${args[0]}" || -L "$proof" || -L "${args[0]}" ]]; then
            echo "$usage";
            exit 1
        fi

        if [[ ! "$root" =~ ^([A-F0-9]+|[a-f0-9]+)$ ]]; then
            echo "$usage";
            exit 1
        fi

        check_proof() {
            lf="$1"
            pf="$2"
            expected_root="$(echo "$3" | awk '{print tolower($0)}')"

            computed="$(sha256sum "$lf" | awk '{print $1}')"

            header_read=0
            while IFS= read -r ln || [ -n "$ln" ]; do
                if [ $header_read -eq 0 ]; then
                    header_read=1
                    # parse "leaf_index:x,tree_size:y"
                    idx_field=$(echo "$ln" | awk -F'[:,]' '{print $2}')
                    size_field=$(echo "$ln" | awk -F'[:,]' '{print $4}')
                    cur_k=$((idx_field - 1))
                    cur_n=$((size_field - 1))
                    continue
                fi

                if [ "$cur_n" -eq 0 ]; then
                    echo "Verification Failed"
                    exit 1
                fi

                if [ $((cur_k & 1)) -gt 0 ] || [ "$cur_k" -eq "$cur_n" ]; then
                    cat_pair="${ln}${computed}"
                    computed="$(printf '%s' "$cat_pair" | xxd -r -p | sha256sum | awk '{print $1}')"
                    while [ $((cur_k & 1)) -eq 0 ]; do
                        cur_k=$((cur_k / 2))
                        cur_n=$((cur_n / 2))
                    done
                else
                    cat_pair="${computed}${ln}"
                    computed="$(printf '%s' "$cat_pair" | xxd -r -p | sha256sum | awk '{print $1}')"
                fi
                cur_k=$((cur_k / 2))
                cur_n=$((cur_n / 2))
            done <"$pf"

            if [ "$cur_n" -eq 0 ] && [ "$computed" = "$expected_root" ]; then
                echo "OK"
                exit 0
            else
                echo "Verification Failed"
                exit 1
            fi
        }

        check_proof "${args[0]}" "$proof" "$root"
        ;;

    *)
        echo "$usage";
        exit 1
        ;;
esac
