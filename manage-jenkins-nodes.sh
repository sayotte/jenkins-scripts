#!/bin/bash
# managed-jenkins-nodes.sh
# Executes common operations for Jenkins nodes in parallel.
# 
# This is an improvement on the jenkins-cli tool and the jenkinsapi.py Python
#   module, both of which can only invoke an operation on a single node at
#   a time (very, *very* slow with more than a handful of nodes).
# 
# This is achieved by sending Groovy code to the Jenkins server over HTTP,
#   where it is evaluated in the context of the running Jenkins instance.

##############################################################################
# Setup a netrc(5)-style file so we can call curl multiple times without
#   re-prompting the user for a password.
# Be sure to delete this file later on! Ideally, use 'trap' to delete it
#   upon script exit.
function setup_netrc_file
{
    if [ $# -lt 2 ]; then
      echo "setup_netrc_file called with too few arguments ($#)" >&2
      return 1
    fi
    local username=$1
    local serverURL=$2

    # Transform a URL 'http://host:port/' to a hostname 'host'
    local serverName=$(printf '%s' "$serverURL" | sed 's|http://||' \
                       | sed 's|\/||' | sed 's|:.*$||')

    # Prompt user for password, read input
    local password
    printf 'Password: ' >&2
    read -s password
    echo >&2
    # Create a tmpfile to use in place of a permanent .netrc
    local netrcFile=$(mktemp)
    chmod 600 "$netrcFile"
    # Populate file according to format found in netrc(5) 
    printf 'machine %s\nlogin %s\npassword %s\n' "$serverName" 'sayotte' "$password" > $netrcFile

    # Print the name of the created file; our caller should be capturing this
    printf '%s' "$netrcFile"
    return 0
}
##############################################################################
# Get an authentication nonce (called a "crumb"), which must be offered as a
#   header field for POST requests to Jenkins as part of its XSS-prevention
#   scheme.
# For reference: https://wiki.jenkins-ci.org/display/JENKINS/Remote+access+API
#   See the "CSRF Protection" section
function get_crumb_header
{
    if [ $# -lt 2 ]; then
      echo "get_crumb_header called with too few arguments ($#)" >&2
      return 1
    fi
    local netrcFile=$1
    local serverURL=$2

    local crumbResponse=$(curl -s --netrc-file "$netrcFile" \
      "$serverURL/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
    if [ $? -ne 0 ]; then
        echo "get_crumb_header: aborting"
        return 2
    fi

    local crumbFieldname=$(printf '%s' "$crumbResponse" | cut -d: -f1)
    local crumbValue=$(printf '%s' "$crumbResponse" | cut -d: -f2)
    printf '%s: %s' "$crumbFieldname" "$crumbValue"
    return 0
}
##############################################################################
function build_groovy_list_from_space_delim_string
{
    local result=''
    for s in $1; do
        if [ -z "$result" ]; then 
            result="[ '$s'"
        else
            result="$result, '$s'"
        fi
    done
    result="$result ]"
    if [ "$result" == ' ]' ]; then
        result="[]"
    fi
    printf '%s' "$result"
}
##############################################################################
function gencode_for_disconnect_nodes
{
    local username="$1"
    local nodeList="$2"

    local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")
    local groovyScript="script= \

    def nodeNames = $groovyNodeArray; 
    def futures = [:];

    for (slave in hudson.model.Hudson.instance.slaves) 
    { 
      if (nodeNames.contains(slave.name)) 
      { 
        def computer = slave.getComputer(); 
        def future = computer.disconnect(new hudson.slaves.OfflineCause.ByCLI(\"Disconnected by $username\"));
        futures[(slave.name)] = future;
      }
    }
    
    futures.each
    { name, future ->
        try {
            future.get();
            println('Disconnect operation for ' + name + ' complete');
        }
        catch (java.util.concurrent.ExecutionException ex)
        {
            println('Exception waiting for ' + name + ': ' + ex.getCause());
        }
    }
    "

    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_connect_nodes
{
    local nodeList="$1"

    local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")
    local groovyScript="script= \

    def nodeNames = $groovyNodeArray; 
    def futures = [:];

    for (slave in hudson.model.Hudson.instance.slaves) 
    { 
      if (nodeNames.contains(slave.name)) 
      { 
        def computer = slave.getComputer(); 
        def future = computer.connect(false);
        futures[(slave.name)] = future;
      }
    }

    futures.each
    { name, future ->
        try {
            future.get();
            println('Connect operation for ' + name + ' complete');
        }
        catch (java.util.concurrent.ExecutionException ex)
        {
            println('Exception waiting for ' + name + ': ' + ex.getCause());
        }
    }
    "
    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_online_nodes
{
    local nodeList="$1"

    local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")
    local groovyScript="script= \
    def nodeNames = $groovyNodeArray; 
    
    // Mark online the nodes requested all at once; this is asynchronous
    for (slave in hudson.model.Hudson.instance.slaves) 
    { 
      if (nodeNames.contains(slave.name)) 
      { 
        def computer = slave.getComputer(); 
        if (computer.isOffline()) 
        { 
          computer.cliOnline();
        }
      }
    }
    
    // Now verify, synchronously, that each node is online
    for (slave in hudson.model.Hudson.instance.slaves)
    {
      if (nodeNames.contains(slave.name))
      {
        slave.getComputer().waitUntilOnline();
        println('Confirmed ' + slave.name + ' is online.');
      }
    }
    "

    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_offline_nodes
{
    local username="$1"
    local nodeList="$2"

    local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")
    groovyScript="script= \
    def nodeNames = $groovyNodeArray; 
    
    // Mark offline the nodes requested all at once; this is asynchronous
    for (slave in hudson.model.Hudson.instance.slaves) 
    { 
      if (nodeNames.contains(slave.name)) 
      { 
        def computer = slave.getComputer(); 
        if (computer.isOnline()) 
        { 
          computer.cliOffline(\"Offlined by $username\");
        }
      }
    }
    
    // Now verify, synchronously, that each node is offline
    for (slave in hudson.model.Hudson.instance.slaves)
    {
      if (nodeNames.contains(slave.name))
      {
        slave.getComputer().waitUntilOffline();
        println('Confirmed ' + slave.name + ' is offline.');
      }
    }
    "

    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_node_labels
{
    local nodeList="$1"

    local groovyScript

    if [ -z "$nodeList" ]; then
        groovyScript="script= 
        for (slave in hudson.model.Hudson.instance.slaves) 
        { 
          println(slave.name + ': ' + slave.getLabelString());
        } 
        "
    else
        local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")
        groovyScript="script= \
        def nodeNames = $groovyNodeArray;

        for (slave in hudson.model.Hudson.instance.slaves)
        {
            if (nodeNames.contains(slave.name))
            {
                println(slave.name + ': ' + slave.getLabelString());
            }
        }
        "
    fi
    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_node_status
{
    local nodeList="$1"

    local groovyNodeArray=$(build_groovy_list_from_space_delim_string "$nodeList")

    groovyScript="script= 
    def node_status_desired(nodename, desiredList)
    {
        if(desiredList.size == 0)
            return true;
        if(desiredList.contains(nodename))
            return true;
        return false;
    }

    def nodeNames = $groovyNodeArray;

    for (slave in hudson.model.Hudson.instance.slaves) 
    {
        if(! node_status_desired(slave.name, nodeNames))
            continue;

        def computer = slave.getComputer();
        print(slave.name + ': ');
        if(computer.isOnline())
        {
            print('online\n');
        }
        else if(computer.isTemporarilyOffline())
        {
            print('offline\n');
        }
        else if(computer.isConnecting())
        {
            print('connecting\n');
        }
        else
        {
            print('disconnected\n');
        }
    } 
    "
    printf '%s' "$groovyScript"
}
##############################################################################
function gencode_for_list_nodes
{
    local groovyScript

    groovyScript="script=
    for (slave in hudson.model.Hudson.instance.slaves)
    {
        println(slave.name);
    }
    "

    printf '%s' "$groovyScript"   
}
##############################################################################
function usage
{
    echo "Usage: $0 <server URL> <username> <command> [arguments ...]"
    echo "  Commands:"
    echo "    connect-nodes <nodename ...>    - Connect to and launch slave agent on nodes"
    echo "    disconnect-nodes <nodename ...> - Disconnect nodes from Jenkins"
    echo "    online-nodes <nodename ...>     - Mark nodes online"
    echo "    offline-nodes <nodename ...>    - Mark nodes administratively offline"
    echo "    node-labels [nodename ...]      - Print labels for all (or specified) nodes"
    echo "    node-status [nodename ...]      - Print status for all (or specified) nodes"
    echo "    list-nodes                      - Print names of all nodes"
}
##############################################################################

# Parse args, shifting off the positional ones so that $* contains only
#   the non-positional arguments.
if [ $# -lt 3 ]; then
    usage
    exit 1
fi
serverURL=$1; shift
username=$1; shift
command=$1; shift

# Generate Groovy code based on the command specified
command=$(printf '%s' "$command" | tr 'A-Z' 'a-z')
case "$command" in
    connect-nodes)
        groovyScript=$(gencode_for_connect_nodes "$*")
        ;;
    disconnect-nodes)
        groovyScript=$(gencode_for_disconnect_nodes "$username" "$*")
        ;;
    online-nodes)
        groovyScript=$(gencode_for_online_nodes "$*")
        ;;
    offline-nodes)
        groovyScript=$(gencode_for_offline_nodes "$username" "$*")
        ;;
    node-labels)
        groovyScript=$(gencode_for_node_labels "$*")
        ;;
    node-status)
        groovyScript=$(gencode_for_node_status "$*")
        ;;
    list-nodes)
        groovyScript=$(gencode_for_list_nodes)
        ;;
    *)
        echo "Unrecognized command '$command'"
        usage
        exit 4
        ;;
esac

# Construct a netrc file (see netrc(5)), which allows us to invoke curl
#   multiple times without re-prompting the user for a password
netrcFile=$(setup_netrc_file "$username" "$serverURL")
if [ ! -r "$netrcFile" ]; then
    echo "netrc file doesn't exist? Aborting."
    exit 2
fi
# Ensure the netrc file is deleted no matter how we exit (note this doesn't
#   cover SIGKILL... don't use that, dummy.)
trap "rm -f $netrcFile" EXIT

# Get a "crumb" from Jenkins. This is similar to a session token, but exists
#   only for XSS/forgery prevention and is not tied to any persistence
#   server-side. Also, it's mandatory.
crumbHeader=$(get_crumb_header "$netrcFile" "$serverURL")
if [ $? -ne 0 ]; then
  echo "Error getting authentication nonce ('crumb') from Jenkins, aborting"
  exit 3
fi

# Use curl to execute the Groovy code in the context of the running Jenkins
#   instance
curl -X POST \
     -H "$crumbHeader" \
     --data-urlencode "$groovyScript" \
     --netrc-file "$netrcFile" \
     "$serverURL"/scriptText

exit $?
