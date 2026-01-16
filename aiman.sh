#!/bin/bash

if [ "$#" -lt 1 ]; then
    echo "Usage: ./aiman.sh -help for help"
    exit 1
fi



KEY_FILE="$HOME/.openrouter_key"
CONTEXT_FILE="/tmp/aiman_context.txt"

#uncomment for testing n stuff
# echo "First argument is: $1"
# echo "Second argument is: $2"

install_self() {
    local target="$HOME/.local/bin/aiman"

    mkdir -p "$HOME/.local/bin"

    if [ -e "$target" ]; then
        echo "aiman is already installed at $target"
        return
    fi

    ln -s "$(realpath "$0")" "$target"
    chmod +x "$(realpath "$0")"

    echo "aiman installed. Restart your shell or run:"
    echo "  source ~/.bashrc"
    echo "You might need to add 'export PATH="$HOME/.local/bin:$PATH"' to your .zshrc if you are using zsh. "
}

uninstall_self() {
    local BIN="$HOME/.local/bin/aiman"
    local KEY_FILE="$HOME/.openrouter_key"
    local CONTEXT_FILE="/tmp/aiman_context.txt"

    echo "Uninstalling aiman..."

    # Remove binary / symlink
    if [ -e "$BIN" ]; then
        rm -i "$BIN"
        echo "Removed $BIN"
    else
        echo "aiman not found in ~/.local/bin"
    fi

    # Ask about config files
    if [ -f "$KEY_FILE" ]; then
        read -r -p "Remove saved API key? (y/n): " a < /dev/tty
        case "$a" in
            [Yy]) rm "$KEY_FILE" ;;
        esac
    fi

    if [ -f "$CONTEXT_FILE" ]; then
        read -r -p "Remove chat context? (y/n): " a < /dev/tty
        case "$a" in
            [Yy]) rm "$CONTEXT_FILE" ;;
        esac
    fi

    echo "Uninstall complete"
}


ensure_path() {
    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        echo "~/.local/bin added to PATH in ~/.bashrc"
    fi
}

remove_path_entry() {
    local rc="$HOME/.bashrc"

    if grep -q '.local/bin' "$rc"; then
        read -r -p "Remove ~/.local/bin from PATH in ~/.bashrc? (y/n): " a
        case "$a" in
            [Yy])
                sed -i.bak '/\.local\/bin/d' "$rc"
                echo "Removed PATH entry (backup saved as .bashrc.bak)"
                ;;
        esac
    fi
}


if [ "$1" = "-install" ]; then
    install_self
    ensure_path
    exit 0
fi

if [ "$1" = "-uninstall" ]; then
    uninstall_self
    remove_path_entry
    exit 0
fi


if [ "$1" = "-help" ]; then
    echo "Usage:"
    echo "  aiman -help -- Show this help message"
    echo "  aiman -key <api-key> -- Set your OpenRouter API key (only needed once)"
    echo "  aiman <command> [question] -- Get information about something on a linux command"
    echo "  aiman -r <message> -- Allows you to respond to the AI's response about the last question"
    echo "  aiman -install -- Install aiman to ~/.local/bin and add to PATH for easy access"
    echo "  aiman -uninstall -- Uninstall aiman from ~/.local/bin and remove from PATH"
    echo "
    Installation doesnt actually install anything, it just makes a symlink to this script in ~/.local/bin. It is also not needed at all, only there for convenience.
    "
    exit 1
fi

if [ "$1" = "-key" ]; then
    api_key="$2"
    echo "$api_key" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "API key saved to $KEY_FILE"
    exit 0
fi

if [ -f "$KEY_FILE" ]; then
    OPENROUTER_API_KEY=$(<"$KEY_FILE")
else
    echo "No API key found, set it with 'aiman -key <openrouter-api-key>'"
    echo "You can get an api key for free at openrouter.ai"
    exit 1
fi

# logic for responding to the ai while keeping context.

ask_clear_context() {
    while true; do
        read -r -p "Clear previous context to ask a new question? (y/n): " answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}


SYSTEMPROMPT="You are a helpful linux command line assistant. You will provide concise and accurate information about linux commands based on user queries. Your responses should be clear and to the point. NO LONG ANSWERS! keep your answers really short, only a couple sentences and an example or two. "

if [ "$1" = "-r" ]; then
    if [ -f "$CONTEXT_FILE" ]; then
        CONTEXT=$(< "$CONTEXT_FILE")
        SYSTEMPROMPT="You are a helpful linux command line assistant. You will provide concise and accurate information about linux commands based on user queries. Your responses should be clear and to the point. Your and the users previous responses are like as below. 
        Your responses will start with \"AI:\" and the users responses will start with \"User:\".
        
        $CONTEXT
        
        Please respond to the last user query accordingly."
        shift
        PROMPT="$*"
    else
        echo "No context found to respond to. Please ask a question first."
        exit 0
    fi
else
    if [ -f "$CONTEXT_FILE" ]; then #if there is context..        
        if [ "$(grep -c '^User:' "$CONTEXT_FILE")" -ge 2 ]; then #and that context has a response (not from the question)..
            echo "Previous context found."
            if ask_clear_context; then # make sure the user wants to clear it.
                rm "$CONTEXT_FILE" 2> /dev/null
                echo "Context cleared."
            else #otherwise
                echo "To ask a new question you must clear past context about other questions."
                exit 0
            fi
        else # if context has no responses, deem it not important and clear it.
            rm "$CONTEXT_FILE" 2> /dev/null
        fi   
    fi


    if [ "$#" -eq 1 ]; then
        PROMPT="Please give a summary of the linux command $1. Include some examples but dont keep it long.  Do not use any markdown blocks, formatting or code blocks. Just plain text."
    fi
    if [ "$#" -eq 2 ]; then
        COMMAND="$1"
        shift
        PROMPT="Please give me info on $* for the linux command $COMMAND. Do not use any markdown blocks, formatting or code blocks. Just plain text."
    fi
fi


#by default ask for commands help:


payload=$(jq -n \
  --arg system "$SYSTEMPROMPT" \
  --arg user "$PROMPT" \
  '{
    model: "xiaomi/mimo-v2-flash:free",
    messages: [
      { role: "system", content: $system },
      { role: "user", content: $user }
    ]
  }'
)


response=$(curl -s https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  | jq -r '.choices[0].message.content // empty'
)
# Save context
touch /tmp/aiman_context.txt

echo 'User: %s\n' "$PROMPT" >> /tmp/aiman_context.txt
printf '\nAI: %s\n' "$response" >> /tmp/aiman_context.txt

echo "$response"