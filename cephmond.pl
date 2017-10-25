#!/usr/bin/perl -w
use strict;
use IO::Socket::INET;
use LWP;
use HTTP::Request::Common;
use JSON;
use Data::Dumper;
# copyright: GPL 3.0
#
# start once every minute via cron

my $carbon_server = '10.11.22.33';
my $carbon_port = 8086;
my $prefix='storage.ceph.node';
my $json = new JSON;

my $laststat='/var/lib/ceph/ceph-graphite-mon.json'; 
my $lock='/var/lib/ceph/ceph-graphite-mon.lock'; 

END {
  unlink($lock);
}

if (-e $lock) {
  my @stat=stat($lock);
  if (time() - $stat[9] > 300 ) {
    if (open(L,"<$lock")){
      my $lpid=<L>;
      chomp($lpid);
      close(L);
      print "lock file $lock exists, try to kill process $lpid\n";
      kill 'HUP',$lpid;
      sleep(1);
      kill -9,$lpid;
    }
  }
  print "lock $lock exists, exiting\n";
  exit(1);
} else {
  open(L,">$lock") or die "can not write lock";
  print L $$;
  close(L);
}


open(S,"ceph -f json node ls --name client.nagios|") or die "$!";

my $j;
$j="";
while(<S>) {
  $j .= $_ ;
}
close(S);
my $ceph_nodes = $json->decode($j);
die "could not parse list of nodes" unless defined $ceph_nodes ;
my $osds=$ceph_nodes->{'osd'};
die "could not read list of osds" unless defined $osds;
my $fqdn=`hostname -f`;
chomp($fqdn);
my @fqdna=split('\.',$fqdn);
my $nodename=$fqdna[0];
print "node name $nodename\n";
# $fqdn='ceph202.eb.lan.at';
my $ownosds=$osds->{$fqdn};
die "no osds on this host (" . $fqdn . ")" unless defined $ownosds;

my @osdlist=@$ownosds;

my $mystats;


foreach  my $osd (@$ownosds) {
  # print "own osd.$osd\n";
  #if (-e "osd.$osd.json") {
  #  open(O,"<osd.$osd.json") or die "$!";
  #} else {
    open(O,"ceph daemon osd.$osd perf dump -f json|") or die "$!";
  #}
  my $osdjson="";
  while(<O>) {
    $osdjson .= $_ ;
  }
  close(O);
  my $ceph_osd ;
  eval {
     $ceph_osd = $json->decode($osdjson);
  };
  my $osdstat=$ceph_osd->{'osd'};

  $mystats->{'subopbytes'} += $osdstat->{'subop_in_bytes'};  
  $mystats->{'oplat'} +=   $osdstat->{'op_latency'}->{'sum'};  
  $mystats->{'oplat.num'} +=   $osdstat->{'op_latency'}->{'avgcount'};  


  $mystats->{'inbytes'} +=    $osdstat->{'op_in_bytes'};
  $mystats->{'outbytes'} +=   $osdstat->{'op_out_bytes'};
  $mystats->{'readops'} +=    $osdstat->{'op_r'};
  $mystats->{'writeops'} +=   $osdstat->{'op_w'};
  $mystats->{'modops'} +=     $osdstat->{'op_rw'};
  $mystats->{'subop'}  +=     $osdstat->{'subop'};  
  # print Dumper($osdstat); 
}

$mystats->{'.time'} = time();

my $oldstat;
if (open(S,"<$laststat")) {
  binmode(S);
  my $os=<S>;
  close(S);
  $oldstat=$json->decode($os);
} 


my $sock = IO::Socket::INET->new(
        PeerAddr => $carbon_server,
        PeerPort => $carbon_port,
        Proto    => 'tcp'
);
die "Unable to connect: $!\n" unless ($sock->connected);

if (defined $oldstat ) {
  my $deltat=60;
  $deltat=  $mystats->{'.time'}  - $oldstat->{'.time'}  if (defined $mystats->{'.time'} and defined $oldstat->{'.time'} );
  # print "delta t is ",$deltat,"\n";
  if ($deltat > 0 ) {
    foreach my $k (keys %$mystats) {
      if ($k =~ /\./ ) {
	 # ignore
      } else {
	if (defined $oldstat->{$k}) {
	  my $val=$mystats->{$k} - $oldstat->{$k};
	  if (defined $mystats->{$k . ".num"}) {
            my $deltan = $mystats->{$k . '.num'}  - $oldstat->{$k . '.num'} ;
            if ( $deltan > 0 ) {
              $val=$val/$deltan;
              #i# print "delta n is $deltan\n";
            } else {
              $val=0;
            }
	  } else {
            $val=$val / $deltat ; 
	  }
	  # print "$k $val \n";
          my $ts=$mystats->{'.time'};
          $val=0 if ($val < 0 );
          print $sock "$prefix.$nodename.$k $val $ts\n";
        }
      }
    }
  }
}
open(S,">$laststat") or die "$!";
print S encode_json $mystats,"\n";
close(S);
unlink($lock);
$sock->shutdown(2);
exit(0);

