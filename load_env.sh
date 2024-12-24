#!/bin/bash

load_env() {
    local env_file="${1:-.env}"  # Use the first argument as the .env file, or default to .env
    local env_path
    
    # Find the .env file in the current directory or parent directories
    env_path=$(find_env_file "$env_file")
    
    if [[ -z "$env_path" ]]; then
        echo "Error: file $env_file not found"
        return 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
            continue
        fi

        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            export "$key=$value"
        fi
    done < "$env_file"
}

find_env_file() {
    local file="$1"
    local dir="$PWD"
    
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/$file" ]]; then
            echo "$dir/$file"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}