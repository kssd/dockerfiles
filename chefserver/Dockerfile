FROM ubuntu
MAINTAINER Kunwar Sangram Singh <kunwar.sangram@gmail.com>

RUN   apt-get update
ENV   DEBIAN_FRONTEND noninteractive

RUN   apt-get install -yq wget
RUN   wget --content-disposition "http://www.opscode.com/chef/download-server?p=ubuntu&pv=12.04&m=x86_64&v=latest&prerelease=false&nightlies=false"
RUN   dpkg -i chef-server*.deb

RUN   dpkg-divert --local --rename --add /sbin/initctl
RUN   ln -sf /bin/true /sbin/initctl

ADD   . /usr/local/bin/
CMD   ["exec_chef_server"]

EXPOSE    443
