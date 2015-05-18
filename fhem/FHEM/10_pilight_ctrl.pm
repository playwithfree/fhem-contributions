##############################################
# $Id: 10_pilight_ctrl.pm 1.02 2015-05-16 Risiko $
#
# Usage
# 
# define <name> pilight_ctrl <host:port> [5.0] 
#
# Changelog
#
# V 0.10 2015-02-22 - initial beta version 
# V 0.20 2015-02-25 - new: dimmer
# V 0.21 2015-03-01 - API 6.0 as default
# V 0.22 2015-03-03 - support more switch protocols
# V 0.23 2015-03-14 - fix: id isn't numeric
# V 0.24 2015-03-20 - new: add cleverwatts protocol
# V 0.25 2015-03-26 - new: cleverwatts unit all
#                   - fix: unit isn't numeric
# V 0.26 2015-03-29 - new: temperature and humidity sensor support (pilight_temp)
# V 0.27 2015-03-30 - new: ignore complete protocols with <protocol>:* in attr ignore
#        2015-03-30 - new: GPIO temperature and humidity sensors
# V 0.28 2015-04-09 - fix: if not connected to pilight-daemon, do not try to send messages
# V 0.29 2015-04-12 - fix: identify intertechno_old as switch
# V 0.50 2015-04-17 - fix: queue of sending messages
#                   - fix: same spelling errors - thanks to pattex
# V 0.51 2015-04-29 - CHG: rename attribute ignore to ignoreProtocol because with ignore the whole device is ignored in FHEMWEB
# V 1.00 2015-05-09 - NEW: white list for defined submodules activating by ignoreProtocol *
# V 1.01 2015-05-09 - NEW: add quigg_gt* protocol (e.q quigg_gt7000)
# V 1.02 2015-05-16 - NEW: battery state for temperature sensors
############################################## 
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use JSON;    #libjson-perl
use Switch;  #libswitch-perl

sub pilight_ctrl_Parse($$);
sub pilight_ctrl_Read($);
sub pilight_ctrl_Ready($);
sub pilight_ctrl_Write($@);
sub pilight_ctrl_SimpleWrite(@);
sub pilight_ctrl_ClientAccepted(@);
sub pilight_ctrl_Send($);

my %sets = ( "reset:noArg" => "");
my %matchList = ( "1:pilight_switch" => "^SWITCH",
                  "2:pilight_dimmer" => "^SWITCH|^DIMMER",
                  "3:pilight_temp"   => "^PITEMP") ;
                  
my @idList   = ("id","systemcode","gpio"); 
my @unitList = ("unit","unitcode","programcode");

#ignore tfa:0,...         list of <protocol>:<id> to ignore
#brands arctech:kaku,...  list of <search>:<replace> protocol names  
#ContactAsSwitch 1234,... list of ids where contact is transformed to switch

sub pilight_ctrl_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";
  require "$attr{global}{modpath}/FHEM/Blocking.pm";

  $hash->{ReadFn}  = "pilight_ctrl_Read";
  $hash->{WriteFn} = "pilight_ctrl_Write";
  $hash->{ReadyFn} = "pilight_ctrl_Ready";
  $hash->{DefFn}   = "pilight_ctrl_Define";
  $hash->{UndefFn} = "pilight_ctrl_Undef";
  $hash->{SetFn}   = "pilight_ctrl_Set";
  $hash->{NotifyFn}= "pilight_ctrl_Notify";
  $hash->{AttrList}= "ignoreProtocol brands ContactAsSwitch ".$readingFnAttributes;
  
  $hash->{Clients} = ":pilight_switch:pilight_dimmer:pilight_temp:";
  #$hash->{MatchList} = \%matchList; #only for autocreate
}

#####################################
sub pilight_ctrl_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a < 3) {
    my $msg = "wrong syntax: define <name> pilight_ctrl hostname:port [5.0]";
    Log3 undef, 2, $msg;
    return $msg;
  }

  DevIo_CloseDev($hash);
  RemoveInternalTimer($hash);
    
  my $me = $a[0];
  my $dev  = $a[2];

  $hash->{DeviceName} = $dev;
  $hash->{STATE} = "defined";
  $hash->{API} = "6.0"; 
  $hash->{API} = "5.0" if (defined($a[3]));
  $hash->{RETRY_INTERVAL} = 60;
  
  $hash->{helper}{CON} = "define";
  $hash->{helper}{CHECK} = 0;
  
  my @sendQueue = ();
  $hash->{helper}->{sendQueue} = \@sendQueue;
  
  my @whiteList = ();
  $hash->{helper}->{whiteList} = \@whiteList;
  
  #$attr{$me}{verbose} = 5;
  
  return pilight_ctrl_TryConnect($hash);
}

sub pilight_ctrl_Close($)
{
  my $hash = shift;
  my $me = $hash->{NAME};
  
  BlockingKill($hash->{helper}{RUNNING_PID}) if(defined($hash->{helper}{RUNNING_PID}));
  
  RemoveInternalTimer($hash);
  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
       defined($defs{$d}{IODev}) &&
       $defs{$d}{IODev} == $hash)
      { 
        delete $defs{$d}{IODev}; 
      } 
  }
  DevIo_CloseDev($hash); 
}

#####################################
sub pilight_ctrl_Undef($$)
{
  my ($hash, $arg) = @_;
  my $me = $hash->{NAME};
  
  pilight_ctrl_Close($hash);
  return undef;
}

#####################################
sub pilight_ctrl_TryConnect($)
{
  my $hash = shift;
  my $me = $hash->{NAME};
  
  $hash->{helper}{CHECK} = 0;
    
  RemoveInternalTimer($hash); 
  
  delete $hash->{NEXT_OPEN};  
  my $ret = DevIo_OpenDev($hash, 0, "pilight_ctrl_DoInit");
  
  delete $hash->{NEXT_OPEN};
  $hash->{helper}{NEXT_TRY} = time()+$hash->{RETRY_INTERVAL};
  
  InternalTimer(gettimeofday()+1,"pilight_ctrl_Check", $hash, 0);
  return $ret;
}

#####################################
sub pilight_ctrl_Set($@)
{
  my ($hash, @a) = @_;

  return "set $hash->{NAME} needs at least one parameter" if(@a < 2);

  my $me   = shift @a;
  my $cmd  = shift @a;

  return join(" ", sort keys %sets) if ($cmd eq "?");

  if ($cmd eq "reset") 
  { 
    pilight_ctrl_Close($hash);
    return pilight_ctrl_TryConnect($hash);
  } 

  return "Unknown argument $cmd, choose one of ". join(" ", sort keys %sets); 
}

#####################################
sub pilight_ctrl_Check($)
{
  my $hash = shift;
  my $me = $hash->{NAME};
  
  RemoveInternalTimer($hash); 
  
  $hash->{helper}{CHECK} = 0 if (!isdigit($hash->{helper}{CHECK}));
  $hash->{helper}{CHECK} +=1;
  Log3 $me, 5, "$me(Check): $hash->{helper}{CON}";
  
  if($hash->{STATE} eq "disconnected" && !defined($hash->{BASE})) {
    Log3 $me, 2, "$me(Check): Could not connect to pilight-daemon $hash->{DeviceName}";
    $hash->{helper}{CON} = "disconnected";
  }
  
  return if ($hash->{helper}{CON} eq "disconnected");
  
  if ($hash->{helper}{CON} eq "define") { 
    Log3 $me, 2, "$me(Check): connection to $hash->{DeviceName} failed";
    $hash->{helper}{CHECK} = 0;
    $hash->{helper}{NEXT_TRY} = time()+$hash->{RETRY_INTERVAL};
    return;
  }
  
  if ($hash->{helper}{CON} eq "identify") {
    if ($hash->{helper}{CHECK} % 3 == 0 && $hash->{helper}{CHECK} < 12) { #retry
      pilight_ctrl_DoInit($hash);
    } elsif ($hash->{helper}{CHECK} >= 12) {
      Log3 $me, 4, "$me(Check): Could not connect to pilight-daemon $hash->{DeviceName} - maybe wrong api version or port";
      DevIo_Disconnected($hash);
      $hash->{helper}{CHECK} = 0;
      $hash->{helper}{CON} = "disconnected";
      $hash->{STATE} = "disconnected";
      $hash->{helper}{NEXT_TRY} = time()+$hash->{RETRY_INTERVAL}; 
      return;
    }
  }
  
  if ($hash->{helper}{CON} eq "identify-failed" || $hash->{helper}{CHECK} > 20) {
    delete $hash->{helper}{CHECK};
    $hash->{helper}{CON} = "disconnected";
    Log3 $me, 2, "$me(Check): identification to pilight-daemon $hash->{DeviceName} failed";
    $hash->{helper}{NEXT_TRY} = time()+$hash->{RETRY_INTERVAL};
    return;
  }
  
  if ($hash->{helper}{CON} eq "identify-rejected" || $hash->{helper}{CHECK} > 20) {
    Log3 $me, 2, "$me(Parse): connection to pilight-daemon $hash->{DeviceName} rejected";
    delete $hash->{helper}{CHECK};
    $hash->{helper}{CON} = "disconnected";
    $hash->{helper}{NEXT_TRY} = time()+$hash->{RETRY_INTERVAL};
    return;
  }
  
  if ($hash->{helper}{CON} eq "connected") {
    delete $hash->{helper}{CHECK};
    delete $hash->{helper}{NEXT_TRY};
    return;
  }
  
  InternalTimer(gettimeofday()+1,"pilight_ctrl_Check", $hash, 0);
  return 1;
}

#####################################
sub pilight_ctrl_DoInit($)
{
  my $hash = shift; 

  return "No FD" if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));

  my $me = $hash->{NAME};  
  my $msg;
  my $api;

  $hash->{helper}{CON} = "identify";

  if ($hash->{API} eq "6.0") {
    $msg = '{"action":"identify","options":{"receiver":1},"media":"all"}';
  } else {
    $msg = "{ \"message\": \"client receiver\" }";
  }
  Log3 $me, 5, "$me(DoInit): send $msg";
  pilight_ctrl_SimpleWrite($hash,$msg);
  return;
}

#####################################
sub pilight_ctrl_Write($@)
{
  my ($hash,$rmsg) = @_;
  my $me = $hash->{NAME};
  
  if ($hash->{helper}{CON} ne "connected") {
    Log3 $me, 2, "$me(Write): ERROR: no connection to pilight-daemon $hash->{DeviceName}";
    return;
  }
  
  my ($cName,$state,@args) = split(",",$rmsg);
    
  my $cType = lc($defs{$cName}->{TYPE});
  Log3 $me, 4, "$me(Write): RCV ($cType) -> $rmsg";
  
  my $proto = $defs{$cName}->{PROTOCOL};
  my $id = $defs{$cName}->{ID};
  my $unit = $defs{$cName}->{UNIT};
  
  $id = "\"".$id."\""   if (!isdigit($id));
  $unit = "\"".$unit."\"" if (!isdigit($unit));
        
  my $code;
  switch($cType){
    case m/switch/  {       
        $code = "{\"protocol\":[\"$proto\"],";
        switch ($proto) {
          case m/elro/          {$code .= "\"systemcode\":$id,\"unitcode\":$unit,";}
          case m/silvercrest/   {$code .= "\"systemcode\":$id,\"unitcode\":$unit,";}
          case m/mumbi/         {$code .= "\"systemcode\":$id,\"unitcode\":$unit,";}
          case m/brennenstuhl/  {$code .= "\"systemcode\":$id,\"unitcode\":$unit,";}
          case m/pollin/        {$code .= "\"systemcode\":$id,\"unitcode\":$unit,";}
          case m/impuls/        {$code .= "\"systemcode\":$id,\"programcode\":$unit,";}
          case m/rsl366/        {$code .= "\"systemcode\":$id,\"programcode\":$unit,";}
          case m/cleverwatts/   { $code .= "\"id\":$id,"; 
                                  if ($unit eq "\"all\"") {
                                    $code .= "\"all\":1,";
                                  } else {
                                    $code .= "\"unit\":$unit,";
                                  }
                                }                                  
          else                  {$code .= "\"id\":$id,\"unit\":$unit,";}
        }
        $code .= "\"$state\":1}";
    }
    case m/dimmer/  {
        $code = "{\"protocol\":[\"$proto\"],\"id\":$id,\"unit\":$unit,\"$state\":1";
        $code .= ",\"dimlevel\":$args[0]" if (defined($args[0]));
        $code .= "}";
    }
    else  {Log3 $me, 3, "$me(Write): unsupported client ($cName) -> $cType"; return;}
  }
  
  return if (!defined($code));
  
  my $msg;
  if ($hash->{API} eq "6.0") {
    $msg = "{\"action\":\"send\",\"code\":$code}";
  } else {
    $msg = "{\"message\":\"send\",\"code\":$code}";
  }
  Log3 $me, 4, "$me(Write): $msg";
  
  # we can't use the same connection because the pilight-daemon close the connection after sending
  # we have to create a second connection for sending data 
  # we do not update the readings - we will do this at the response message
  
  push @{$hash->{helper}->{sendQueue}}, $msg;
  pilight_ctrl_SendNonBlocking($hash); 
}

#####################################
sub pilight_ctrl_Send($)
{
  my ($string) = @_;
  my ($me, $host,$data) = split("\\|", $string);
  my $hash = $defs{$me};
  
  my ($remote_ip,$remote_port) = split(":",$host);

  my $socket = new IO::Socket::INET (
    PeerHost => $remote_ip,
    PeerPort => $remote_port,
    Proto => 'tcp',
  ); 
  
  if (!$socket) {
    Log3 $me, 2, "$me(Send): ERROR. Can't open socket to pilight-daemon $remote_ip:$remote_port";
    return "$me|0";
  } 
  
  # we only need a identification to send in 5.0 version
  if ($hash->{API} eq "5.0") {    
    my $msg = "{ \"message\": \"client sender\" }";
    my $rcv;
    $socket->send($msg);
    $socket->recv($rcv,1024);
    $rcv =~ s/\n/ /g;
    
    Log3 $me, 5, "$me(Send): RCV -> $rcv";
    
    my $json = JSON->new;
    my $jsondata = $json->decode($rcv);

    if (!$jsondata)
    {
      Log3 $me, 2, "$me(Send): ERROR. no JSON response message";
      $socket->close();
      return "$me|0"; 
    }
    
    my $ret = pilight_ctrl_ClientAccepted($hash,$jsondata);
    if ( $ret != 1 ) {
      Log3 $me, 2, "$me(Send): ERROR. Connection rejected from pilight-daemon";
      $socket->close();
      return return "$me|0";
    }
  }
  
  Log3 $me, 5, "$me(Send): $data";
  $socket->send($data);
  
  #6.0 we get a response message
  if ($hash->{API} eq "6.0") {
    my $rcv;
    $socket->recv($rcv,1024);
    $rcv =~ s/\n/ /g;
    Log3 $me, 5, "$me(Send): RCV -> $rcv";
  }
  $socket->close();
  
  return "$me|1";
}

#####################################
sub pilight_ctrl_addWhiteList($$)
{
  my ($own, $dev) = @_;
  my $me = $own->{NAME};
  my $devName = $dev->{NAME};
  
  Log3 $me, 4, "$me(addWhiteList): add $devName to white list";
  my $entry = {};
  
  my $id =       (defined($dev->{ID}))       ? $dev->{ID}      : "";
  my $protocol = (defined($dev->{PROTOCOL})) ? $dev->{PROTOCOL}: "";
  
  my %whiteHash;
  @whiteHash{@{$own->{helper}->{whiteList}}}=();
  if (!exists $whiteHash{"$protocol:$id"}) { 
    push @{$own->{helper}->{whiteList}}, "$protocol:$id";
  }
}

#####################################
sub pilight_ctrl_createWhiteList($)
{
  my ($own) = @_;
  splice($own->{helper}->{whiteList});
  foreach my $d (keys %defs)   
  { 
    my $module   = $defs{$d}{TYPE};
    next if ($module !~ /pilight_[d|s|t].*/);
    
    pilight_ctrl_addWhiteList($own,$defs{$d});
  }
}

#####################################
sub pilight_ctrl_Notify($$)
{
  my ($own, $dev) = @_;
  my $me = $own->{NAME}; # own name / hash
  my $devName = $dev->{NAME}; # Device that created the events
  
  return undef if ($devName ne "global");
  
  my $max = int(@{$dev->{CHANGED}}); # number of events / changes
  for (my $i = 0; $i < $max; $i++) {
    my $s = $dev->{CHANGED}[$i];
    
    next if(!defined($s));
    if ( $s =~/DEFINED/ or $s =~/INITIALIZED/ or $s =~/DELETED/) {
      Log3 $me, 4, "$me(Notify): create white list";
      pilight_ctrl_createWhiteList($own);
    }
  }
  return undef;
}

#####################################
sub pilight_ctrl_SendDone($)
{
  my ($string) = @_;
  my ($me, $ok) = split("\\|", $string);
  my $hash = $defs{$me};
  
  Log3 $me, 4, "$me(SendDone): message successfully send" if ($ok);
  
  delete($hash->{helper}{RUNNING_PID});
}

#####################################
sub pilight_ctrl_SendAbort($)
{
  my ($hash) = @_;
  my $me = $hash->{NAME};
  
  Log3 $me, 2, "$me(SendAbort): ERROR. sending aborted";
  
  delete($hash->{helper}{RUNNING_PID});
}

#####################################
sub pilight_ctrl_SendNonBlocking($)
{
  my ($hash) = @_;
  my $me = $hash->{NAME};
  
  RemoveInternalTimer($hash); 
  
  my $queueSize = @{$hash->{helper}->{sendQueue}};
  Log3 $me, 5, "$me(SendNonBlocking): queue size $queueSize"; 
  
  return if ($queueSize <=0);
  
  if (!(exists($hash->{helper}{RUNNING_PID}))) {    
    my $data = shift @{$hash->{helper}->{sendQueue}};    
    
    my $blockingFn = "pilight_ctrl_Send";
    my $arg        = $me."|".$hash->{DeviceName}."|".$data;
    my $finishFn   = "pilight_ctrl_SendDone";
    my $timeout    = 4;
    my $abortFn    = "pilight_ctrl_SendAbort";
  
    $hash->{helper}{RUNNING_PID} = BlockingCall($blockingFn, $arg, $finishFn, $timeout, $abortFn, $hash);
    $hash->{helper}{LAST_SEND_RAW} = $data;
  } else {
    Log3 $me, 5, "$me(Write): Blocking Call running - will try it later";     
  }
  
  InternalTimer(gettimeofday()+0.5,"pilight_ctrl_SendNonBlocking", $hash, 0) if ($queueSize > 0);
}

#####################################
sub pilight_ctrl_ClientAccepted(@)
{
  my ($hash,$data) = @_;
  my $me = $hash->{NAME};
  
  my $ret = 0;
  if ($hash->{API} eq "5.0") {
    my $msg = (defined($data->{message})) ? $data->{message} : "";
    $ret = 1  if(index($msg,"accept") >= 0);
    $ret = -1 if(index($msg,"reject") >= 0);
  }
  else {
    my $status = (defined($data->{status})) ? $data->{status} : "";
    $ret = 1  if(index($status,"success") >= 0);
    $ret = -1 if(index($status,"reject") >= 0);
  }
  return $ret;
}


#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub pilight_ctrl_Read($)
{
  my ($hash) = @_;
  my $me = $hash->{NAME};
  
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));

  my $recdata = $hash->{PARTIAL};
  #Log3 $me, 5, "$me(Read): RCV->$buf"; 
  $recdata .= $buf;

  while($recdata =~ m/\n/) 
  {
    my $rmsg;
    ($rmsg,$recdata) = split("\n", $recdata, 2);
    $rmsg =~ s/\r//;    
    pilight_ctrl_Parse($hash, $rmsg) if($rmsg);
  }
  $hash->{PARTIAL} = $recdata;
}

###########################################
sub pilight_ctrl_Parse($$)
{
  my ($hash, $rmsg) = @_;
  my $me = $hash->{NAME};

  Log3 $me, 4, "$me(Parse): RCV -> $rmsg";

  next if(!$rmsg || length($rmsg) < 1);

  $hash->{helper}{LAST_RCV_RAW} = $rmsg;

  my $json = JSON->new;
  my $data = $json->decode($rmsg);
  return if (!$data);
  
  if ($hash->{helper}{CON} eq "identify")  # we are in identify process
  { 
    $hash->{helper}{CON} = "identify-failed";
    my $ret = pilight_ctrl_ClientAccepted($hash,$data);
    
    switch ($ret) {
      case 1  { $hash->{helper}{CON} = "connected"; }
      case -1 { $hash->{helper}{CON} = "identify-rejected"; }
      else    { Log3 $me, 3, "$me(Parse): internal error"; }
    }
    pilight_ctrl_Check($hash);
    return;
  }

  $hash->{helper}{LAST_RCV_JSON} =  $json;
  
  my $proto = (defined($data->{protocol})) ? $data->{protocol} : "";
  if (!$proto)
  {
    Log3 $me, 3, "$me(Parse): unknown message -> $rmsg";
    return;
  }

  #brands
  my @brands = split(",",AttrVal($me, "brands",""));
  foreach my $brand (@brands){
    my($search,$replace) = split(":",$brand);
    next if (!defined($search) || !defined($replace));
    $proto =~ s/$search/$replace/g;
  } 

  $hash->{helper}{LAST_RCV_PROTOCOL} = $proto;
  
  my $s           = ($hash->{API} eq "5.0")            ? "code" : "message";
  my $state       = (defined($data->{$s}{state}))      ? $data->{$s}{state}       : "";
  my $all         = (defined($data->{$s}{all}))        ? $data->{$s}{all}         : "";
 
  my $id = "";
  foreach my $sid (@idList) {
    $id          = (defined($data->{$s}{$sid}))        ? $data->{$s}{$sid}        : ""; 
    last if ($id ne "");
  }
  
  my $unit = "";
  foreach my $sunit (@unitList) {
    $unit          = (defined($data->{$s}{$sunit}))    ? $data->{$s}{$sunit}      : ""; 
    last if ($unit ne "");
  }

  my @ignoreIDs = split(",",AttrVal($me, "ignoreProtocol","")); 
  
  # white or ignore list
  if (@ignoreIDs == 1 && $ignoreIDs[0] eq "*"){ # use list
      my %whiteHash;
      @whiteHash{@{$hash->{helper}->{whiteList}}}=();
      if (!exists $whiteHash{"$proto:$id"}) {
        Log3 $me, 4, "$me(Parse): $proto:$id not in white list";
        return;
      }
  } else {  #ignore list
    my %ignoreHash;
    @ignoreHash{@ignoreIDs}=();  
    if (exists $ignoreHash{"$proto:$id"} || exists $ignoreHash{"$proto:*"}) {
      Log3 $me, 5, "$me(Parse): $proto:$id is in ignoreProtocol list";
      return;
    }
  }
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash,"rcv_raw",$rmsg);
  readingsEndUpdate($hash, 1);
  
  $unit = "all" if ($unit eq "" && $all ne "");
  
  my $protoID = -1;  
  switch($proto){
    #switch
    case m/switch/      {$protoID = 1;}
    case m/elro/        {$protoID = 1;}
    case m/silvercrest/ {$protoID = 1;}
    case m/mumbi/       {$protoID = 1;}
    case m/brennenstuhl/{$protoID = 1;}
    case m/pollin/      {$protoID = 1;}
    case m/impuls/      {$protoID = 1;}
    case m/rsl366/      {$protoID = 1;}
    case m/cleverwatts/ {$protoID = 1;}
    case m/intertechno_old/ {$protoID = 1;}
    case m/quigg_gt/    {$protoID = 1;}
    
    case m/dimmer/      {$protoID = 2;}
    case m/contact/     {$protoID = 3;}
    
    #Weather Stations temperature, humidity
    case m/alecto/      {$protoID = 4;}
    case m/auriol/      {$protoID = 4;}
    case m/ninjablocks/ {$protoID = 4;}
    case m/tfa/         {$protoID = 4;}
    case m/teknihall/   {$protoID = 4;}
    
    #gpio temperature, humidity sensors
    case m/dht11/       {$protoID = 4;}
    case m/dht22/       {$protoID = 4;}
    case m/ds18b20/     {$protoID = 4;}
    case m/ds18s20/     {$protoID = 4;}
    case m/cpu_temp/    {$protoID = 4;}
    case m/lm75/        {$protoID = 4;}
    case m/lm76/        {$protoID = 4;}
    
    case m/screen/      {return;}
    case m/firmware/    {return;}    
    else                {Log3 $me, 3, "$me(Parse): unknown protocol -> $proto"; return;}
  }
  
  if ($id eq "") {
      Log3 $me, 3, "$me(Parse): ERROR no or unknown id $rmsg";
      return;
  }
    
  switch($protoID){
    case 1 { return Dispatch($hash, "SWITCH,$proto,$id,$unit,$state",undef ); }
    case 2 {
      my $dimlevel = (defined($data->{$s}{dimlevel})) ? $data->{$s}{dimlevel} : "";
      my $msg = "DIMMER,$proto,$id,$unit,$state";
      $msg.= ",$dimlevel" if ($dimlevel ne "");
      return Dispatch($hash, $msg ,undef);
    }
    case 3 {
      my $asSwitch = $attr{$me}{ContactAsSwitch};
      if ( defined($asSwitch) && $asSwitch =~ /$id/) {
        $proto =~ s/contact/switch/g;
        $state =~ s/opened/on/g;
        $state =~ s/closed/off/g;
        Log3 $me, 5, "$me(Parse): contact as switch for $id";
        return Dispatch($hash, "SWITCH,$proto,$id,$unit,$state",undef);
      }
      return;
    }
    case 4 {
        my $temp = (defined($data->{$s}{temperature})) ? $data->{$s}{temperature} : "";
        return if ($temp eq "");
        
        my $humidity = (defined($data->{$s}{humidity})) ? $data->{$s}{humidity} : "";
        my $battery = (defined($data->{$s}{battery})) ? $data->{$s}{battery} : "";
        
        my $msg = "PITEMP,$proto,$id,$temp,$humidity,$battery";
        return Dispatch($hash, $msg,undef);
    }
    else  {Log3 $me, 3, "$me(Parse): unknown protocol -> $proto"; return;}
  }
  return;
}

#####################################
# called from gobal loop to try reconnection
sub pilight_ctrl_Ready($)
{
  my ($hash) = @_;
  my $me = $hash->{NAME};  
  
  if($hash->{STATE} eq "disconnected" && !defined($hash->{BASE}))
  {
    return if(defined($hash->{helper}{NEXT_TRY}) && $hash->{helper}{NEXT_TRY} && time() < $hash->{helper}{NEXT_TRY});
    return pilight_ctrl_TryConnect($hash);
  }
}

#####################################
sub pilight_ctrl_SimpleWrite(@)
{
  my ($hash, $msg, $nonl) = @_;
  return if(!$hash);
 
  my $me = $hash->{NAME};
  Log3 $me, 4, "$me(SimpleWrite): snd -> $msg";

  $msg .= "\n" unless($nonl);

  DevIo_SimpleWrite($hash,$msg,0);
}

1;

=pod
=begin html

<a name="pilight_ctrl"></a>
<h3>pilight_ctrl</h3>
<ul>

  pilight_ctrl is the base device for the communication (sending and receiving) with the pilight-daemon.<br>
  You have to define client devices e.q. pilight_switch for switches.<br>
  Further information to pilight: <a href="http://www.pilight.org/">http://www.pilight.org/</a><br><br>
  Further information to pilight protocols: <a href="http://wiki.pilight.org/doku.php/protocols#protocols">http://wiki.pilight.org/doku.php/protocols#protocols</a><br>
  Currently supported: <br>
  <ul>
    <li>Switches:</li>
    <li>Dimmers:</li>
    <li>Temperature and humitity sensors</li>
  </ul>
  
  <br><br>

  <a name="pilight_ctrl_define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; pilight_ctrl ip:port [api]</code>
    ip:port is the IP address and port of the pilight-daemon<br>
    api specifies the pilight api version - default 6.0<br>
    <br>
    Example:
    <ul>
      <code>define myctrl pilight_ctrl localhost:5000 5.0</code><br>
      <code>define myctrl pilight_ctrl 192.168.1.1:5000</code><br>
    </ul>
  </ul>
  <br>
  <a name="pilight_ctrl_set"></a>
  <p><b>Set</b></p>
  <ul>
    <li>
      <b>reset</b>
    </li>
  </ul>
  <br>
  <a name="pilight_ctrl_readings"></a>
  <p><b>Readings</b></p>
  <ul>    
    <li>
      rcv_raw<br>
      The last complete received message in json format.
    </li>
  </ul>
  <br>
  <a name="pilight_ctrl_attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a name="ignoreProtocol">ignoreProtocol</a><br>
        Comma separated list of protocol:id combinations to ignore.<br>
        protocol:* ignores the complete protocol.<br>
        * All incomming messages will be ignored. Only protocol id combinations from defined submodules will be accepted<br>
        Example: 
        <li><code>ignoreProtocol tfa:0</code></li>
        <li><code>ignoreProtocol tfa:*</code></li>
        <li><code>ignoreProtocol *</code></li>
    </li>
    <li><a name="brands">brands</a><br>
        Comma separated list of <search>:<replace> combinations to rename protocol names. <br>
        pilight uses different protocol names for the same protocol e.q. arctech_switch and kaku_switch<br>
        Example: <code>brands archtech:kaku</code>
    </li>
    <li><a name="ContactAsSwitch">ContactAsSwitch</a><br>
        Comma separated list of ids which correspond to a contact but will be interpreted as switch. <br>
        In this case opened will be interpreted as on and closed as off.<br>
        Example: <code>ContactAsSwitch 12345</code> 
    </li>
  </ul>
  <br>

</ul>

=end html

=cut
