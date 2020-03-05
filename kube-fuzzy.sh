#
# Function and aliases to utilise skim and bat to edit kubernetes pods and deployments
#
# Requirements:
#       sk  (https://github.com/lotabout/skim)
#       bash >= v4, zsh, or any other shell with associative array support
#       kubectl
#
#       Optional:
#           bat (https://github.com/sharkdp/bat) for the --events formatting flag
#
# Usage:
#       Source the file in your shell, or add to your rc file
#       See the commands array for keybindings, which by default are:
#           - ctrl-e: Edit selected resources after exit
#           - ctrl-t: Delete currently highlighted resource*
#           - ctrl-b: Describe selected resources after exit
#           - ctrl-l: Log selected pods after exit
#           - ctrl-k: Get containers of selected pod, and display their logs in sk
#           - ctrl-o: Base64 decode the data fields of selected secret after exit
#           - ctrl-n: No action, defaults to outputting selected objects
#       These keybinds and their behaviour can be changed, see #Configuring#Defining keybinds
#
# Configuring:
#       Defining keybinds:
#           - Keybinds are defined in the commands array, in the form ['action']='key(s)'
#           - Actions are defined in the actions variable, which cannot have leading whitespace and are seperated by newlines
#       Selection + actions:
#           - Actions can run in place (see 'delete'), or after sk exits by writing to the action file
#           - Accepting the selection of a kubernetes resource (or multiple with Tab) will execute the last action written to the action file
#       Executing actions:
#           - Escaping / cancelling is handled when executing actions
#           - Some actions can be type specific (eg. logs) by comparing against the $1 parameter. This should be handled when executing the action
#       Preview window:
#           - The preview window will execute `$SHELL -c` on the string passed to the --preview flag each time a line is highlighted
#
#       *By default the 'delete' action does not act on the current selection, or wait for the selection to be accepted to execute.
#           The currently highlighted line is subsituted instead, see `man sk` and the execute() paired with 'delete' in actions for details
#

function kube_fuzzy () {
    # Handle arguments / flags
    resource=${1}
    eventsFlag=false

    if [[ -z $resource ]]; then
        echo "Error: A resource is required" >&2
        return 1
    fi
    if [[ ${2} == "--events" ]] || [[ ${2} == "-e" ]]; then
        eventsFlag=true
    fi

    # Temporary files for reading / writing data from skim
    local tempFile=$(mktemp /tmp/kube_fuzzy.XXXXXXXXXXXX)
    local actionFile=$(mktemp /tmp/kube_fuzzy.command.XXXXXXXXXXXX)
    echo "none" > $actionFile

    # Key bindings
    declare -A commands
    commands+=(
            ["none"]="ctrl-n"
            ["delete"]="ctrl-t"
            ["edit"]="ctrl-e"
            ["describe"]="ctrl-b"
            ["logs"]="ctrl-l"
            ["containers"]="ctrl-k"
            ["decode"]="ctrl-o"
    )

    # Declare actions to be inputted to --bind
    actions=$(
echo -e "${commands[none]}:execute(echo 'none' > $actionFile)
${commands[delete]}:execute(kubectl delete ${resource} {1})
${commands[edit]}:execute(echo 'edit' > $actionFile)
${commands[describe]}:execute(echo 'describe' > $actionFile)
${commands[logs]}:execute(echo 'logs' > $actionFile)
${commands[containers]}:execute(echo 'containers' > $actionFile)
${commands[decode]}:execute(echo 'decode' > $actionFile)" | tr '\n' ',')

    # Launch sk and store the output
    local result=$(kubectl get $resource |
    sk -m --ansi --preview "{
        echo \"Last selected action was: \$(cat $actionFile) (updates with preview window)\";
        echo '';
        kubectl describe ${resource} {1} > $tempFile;
        if [[ $eventsFlag == true ]]; then
            lines=\$(echo \$(wc -l < $tempFile));
            eventsLine=\$(cat $tempFile | grep -n 'Events:' | cut -d: -f 1);
            echo \"-------------------------------------------------------------\"
            bat $tempFile --line-range \$eventsLine:\$lines; 
            echo \"-------------------------------------------------------------\"
        fi
        less -e $tempFile;
        }" --bind "ctrl-c:abort,$actions") # Binding to capture ctrl-c so that temp files are properly cleaned

    if [[ -z $result ]]; then       # No selection made, cleanup and return
        rm $tempFile
        rm $actionFile
        echo "Aborted" >&2
        return 4
    fi

    # Cleanup temporary files, retrieve the action to run
    rm $tempFile
    local action=$(cat $actionFile)
    rm $actionFile

    # Execute selected action
    if [[ "$action" != "none" ]]; then
        local result=$(echo $result | awk '{ print $1 }' | tr '\n' ' ') # Format result to be usable for multiline inputs

        # Global actions
        case $action in
            edit)
                kubectl edit $resource $(echo $result);;
            describe)
                kubectl describe $resource $(echo $result);;
            *)
                # Check for type specific actions
                case $resource in      
                    pods)
                        case $action in
                            logs)
                                if [[ $result == *" "* ]]; then
                                    echo "WIP: Can't currently log multiple pods" >&2
                                    return 6
                                else
                                    kubectl logs $(echo $result)
                                fi
                                ;;
                            containers)
                                if [[ $result == *" "* ]]; then
                                    echo "WIP: Can't currently handle multiple pods' containers" >&2
                                    return 6
                                else
                                    echo "Fetching containers..."
                                    contNames=$(printf '%s\n' $(kubectl get pods $result -o jsonpath='{.spec.containers[*].name}'))
                                    initContNames=$(printf '%s\n' $(kubectl get pods $result -o jsonpath='{.spec.initContainers[*].name}'))
                                    logCont=$(echo -e "$contNames\n$initContNames" | sk --ansi --preview "kubectl logs $result -c {}")
                                    if [[ ! -z $logCont ]]; then
                                        kubectl logs $result -c $logCont
                                    fi
                                fi
                                ;;
                            *)
                                echo "Error: Can't execute '${action}' on resource ${1}" >&2
                                return 5;;
                        esac;;
                    secrets)
                        case $action in
                            decode)
                                if [[ $result == *" "* ]]; then
                                    echo "WIP: Can't decode the data of multiple secrets"
                                    return 6
                                else
                                    toSplit=$(kubectl get secrets $(echo $result) -o jsonpath='{.data}')
                                    toSplit=$(echo $toSplit | cut -c 5- | sed 's/.$//')
                                    splitArr=($(echo "$toSplit" | tr ':' ' '))
                                    echo "Fetched values for $result:"
                                    echo "${splitArr[*]}"
                                    echo ''
                                    echo "Decoded values for $result:"
                                    count=0
                                    for item in ${splitArr[@]}; do
                                        if [[ ! $(( $count % 2 )) -eq 0 ]]; then
                                            echo $(echo $item | base64 -d)
                                        else
                                            printf "$item: "
                                        fi
                                        ((count++))
                                    done
                                fi
                                ;;
                            *)
                                echo "Error: Can't execute '${action}' on resource ${1}" >&2
                                return 5;;
                        esac;;
                    *)
                        echo "Error: Can't execute '${action}' on resource ${1}" >&2
                        return 5;;
                esac
        esac
    else    # Selection made with no command
        echo -e "$result"
    fi
}

alias kgp="kube_fuzzy pods --events"
alias kgd="kube_fuzzy deployments --events"
alias kgs="kube_fuzzy services --events"
alias kgsec="kube_fuzzy secrets"