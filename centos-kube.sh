#!/usr/bin/sh

# Get the host/ip of this server
master_hostname=`hostname`
master_ip=`ip addr | egrep -v "lo:|127.0.0.1|::1" | egrep "^[0-9]:|inet"|head -n2|awk '/inet/{print $2}'|cut -d'/' -f1`
hosts=""
overlay_cidr="10.244.0.0/16"

verify_master_node () {
    echo -n "Master node hostname($master_hostname): "
    read hostname
    if [ "$hostname" != "" ]
    then
        hostname $hostname
        master_hostname=$hostname
    fi

    echo -n "Master node IP($master_ip): "
    read ip
    if [ "$ip" != "" ]
    then
        master_ip=$ip
    fi
}


get_nodes () {
    hosts=""
    hostname=" "

    while [ "$hostname" != "" ]
    do
        echo -n "Enter hostname of node(leave blank to complete): "
        read hostname
        if [ "$hostname" == "" ]
        then
            break
        fi
        echo -n "Enter IP address of ($hostname): "
        read ip
        hosts="$hosts $hostname/$ip"
    done

    # Strip preceding space
    hosts=`echo $hosts`
}


confirmed=0

confirm () {
    echo
    echo " Confirmation"
    echo "=============="
    echo "Master node hostname: $master_hostname"
    echo "Master node IP: $master_ip"
    i=1
    for host in $hosts
    do
        hostname=$(echo $host | cut -d'/' -f1)
        ip=$(echo $host | cut -d'/' -f2)
        echo "Node $i: $hostname"
        echo "Node $i IP: $ip"
        i=$((i+1))
    done
    echo "Overlay network CIDR: $overlay_cidr"
    echo
    confirmation=''
    while [ "$confirmation" == "" ]
    do
        echo -n "Is the above information correct? (Y/n) "
        read confirmation
        if [ "$confirmation" == "n" ] || [ "$confirmatio" == "N" ]
        then
            break
        elif [ "$confirmation" == "" ] || [ "$confirmation" == "y" ] || [ "$confirmation" == "Y" ]
        then
            confirmed=1
            break
        else
            confirmation=""
        fi
    done
    
}

disable_selinux () {
  setenforce 0
  sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux 
}

enable_bridging () {
    grep net.bridge.bridge-nf-call-ip6tables /etc/sysctl.conf || echo net.bridge.bridge-nf-call-ip6tables = 1 >> /etc/sysctl.conf
    grep net.bridge.bridge-nf-call-iptables /etc/sysctl.conf || echo net.bridge.bridge-nf-call-iptables = 1 >> /etc/sysctl.conf
    sed -i 's/net.bridge.bridge-nf-call-ip6tables = 0/net.bridge.bridge-nf-call-ip6tables = 1/g' /etc/sysctl.conf
    sed -i 's/net.bridge.bridge-nf-call-iptables = 0/net.bridge.bridge-nf-call-iptables = 1/g' /etc/sysctl.conf
}

disable_swap () {
    sed -i 's/^\/.\+[\t ]swap[\t ]/# &/g' /etc/fstab
}

install_kubernetes () {
    kube_repo=/etc/yum.repos.d/kubernetes.repo
    mv $kube_repo $kube_repo.bak-`date +"%Y%m%d"` 2> /dev/null  
    echo "[kubernetes]" > $kube_repo
    echo "name=Kubernetes" >> $kube_repo
    echo "baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-"`uname -r|sed -e 's/.\+el/el/g'|sed -e's/\./-/g'` >> $kube_repo
    echo >> $kube_repo
    echo "enabled=1" >> $kube_repo
    echo "gpgcheck=1" >> $kube_repo
    echo "repo_gpgcheck=1" >> $kube_repo
    echo "gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg" >> $kube_repo
    echo "       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg" >> $kube_repo
    yum install -y kubeadm docker
    systemctl start docker && systemctl start kubelet
    systemctl enable docker && systemctl enable kubelet
}

build_hosts () {
    # Create a temp file to work with
    tmphosts=$(mktemp /tmp/centos-kube_hosts.XXXXXX)

    # Prevent duplicate entries by filtering out hosts that match the ones being added
    regex=`echo "$1|\# kubernetes hosts" | sed -e 's/\/[0-9\.]\+ /|/g'`
    egrep -v "$regex" /etc/hosts > $tmphosts

    # Populate hosts file with kubernetes nodes
    echo "# kubernetes hosts" >> $tmphosts
    for host in $1
    do
        hostname=$(echo $host | cut -d'/' -f1)
        ip=$(echo $host | cut -d'/' -f2)
        echo "$ip	$hostname" >> $tmphosts
    done
    echo
    cat $tmphosts > /etc/hosts
    rm -f $tmphosts
}
while [ $confirmed -ne 1 ]
do
    verify_master_node
    get_nodes
    echo -n "Enter overlay network CIDR ($overlay_cidr):"
    read cidr
    if [ "$cidr" != "" ]
    then
        overlay_cidr=$cidr
    fi
    confirm
done

disable_selinux
enable_bridging
disable_swap
install_kubernetes
build_hosts "$master_hostname/$master_ip $hosts"

for host in $hosts
do
    hostname=$(echo $host | cut -d'/' -f1)
    ip=$(echo $host | cut -d'/' -f2)
    echo "$ip	$hostname"
    ssh $ip <<- EOF
        $(declare -f)
        disable_selinux
        enable_bridging
        disable_swap
        install_kubernetes
        build_hosts "$master_hostname/$master_ip $hosts"
EOF
done

kubeadm init --pod-network-cidr=$overlay_cidr
