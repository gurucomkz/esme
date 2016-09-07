#!/usr/bin/perl

use Net::SMPPSSL;
use Digest::MD5;
use Switch;
use DBI;
use Time::HiRes qw ( setitimer ITIMER_REAL time );
use IO::Select;
use IO::Socket;
#use Time::Local;
use Text::Iconv;

require Encode;
#Config
$sms_ip = "";
$sms_port = "";
$sms_sys_id = "";
$sms_pass = "";
$sms_sys_type = NULL;

$HTTP_DOM = ""; #website domain
$from = 'example.com'; #from name
$to = ''; #admin number just in case

$host_name = "localhost";
$db_name = "esme_base";
$db_password = "";

my $pdu;
my $sms;
my $smpp_t;
my $died = 0;

$dsn = "DBI:mysql:host=$host_name;database=$db_name";

$dom = -1;
#
# makes record to a log
#
sub rep
{
    my ($repmsg) = @_;
    ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year +=1900;
    $mon ++;
    print "$year.$mon.$mday $hour:$min:$sec $repmsg\n";

    $dbh->do("INSERT INTO `pan_eventlog` (`le_timestamp`, `le_text`) VALUES (UNIX_TIMESTAMP(), ?  )",
                			 undef, $repmsg );

}
#@ TRIM
sub trim
{
	my $str = shift;

	return "" if !defined $str;
	$str =~ s/^\s+//;
	$str =~ s/\s+$//;
	return ($str);
}
#@ TRIM


sub gen_string
{
    my ($rlen) = @_;
    $rlen = 8 if !$rlen;

    my $md = Digest::MD5->new ();

    $md->add (localtime (time ()));	# add current time
    $md->add (rand ());				# add random number
    $md->add ($$);					# add current process ID
    return (substr ($md->hexdigest(),0,$rlen) );
}

sub explain_status
{
   my ($code) = @_;
   return Net::SMPPSSL::status_code->{$code}->{msg}." [".Net::SMPPSSL::status_code->{$code}->{code}."] ($code)";
}
sub connect_transport
{
    ($smpp_t,$err) =
    #Net::SMPPSSL->new_transceiver(
    Net::SMPPSSL->new_reciever(
        $sms_ip,
        port=>$sms_port,
        system_id =>$sms_sys_id,
        password => $sms_pass,
        system_type=>$sms_sys_type,
		interface_version=>0x34
    ) or die;
    $statusmsg = explain_status($err->{status});
    rep ("Connect-transceiver. Status=$statusmsg ($err->{status})");
		die("ESME is already running\n") if( $err->{status} ne 0 ) ;
}

sub disconnect_transport
{
   $smpp_t->unbind();
}

sub connect
{
	return (DBI->connect ($dsn, "root", $db_password,
							{PrintError => 1, RaiseError => 1}));
}

sub Send{
    my ($dest_addr,$msgtext,$src_addr,$msgo_id,$reqstatus) = @_;
	my $dcoding = 0x00;
	my $msgtext1 = $msgtext;
	my $registered_delivery = 0x00;

	if ($msgtext =~ m/[\x80-\xFF]/) {
		my $converter = Text::Iconv->new("CP1251", "ucs-2be");
		$msgtext1 = $converter->convert($msgtext);
		$dcoding = 0x08;
	}

	if($reqstatus eq '1') {
		$registered_delivery = 0x01;
		#rep("registered_delivery ON");
	}

    $resp = $smpp_t->submit_sm(
        protocol_id=>0x00,
		service_type=>0x00,
        validity_period=>'',
        source_addr_ton => 0x05,
        source_addr_npi => 0x01,
        source_addr => $src_addr,
        dest_addr_ton => 0x01,
		dest_addr_npi => 0x01,
        destination_addr => $dest_addr,
        data_coding => $dcoding,
        short_message=> $msgtext1,
        esm_class => 0x00,
		registered_delivery => $registered_delivery
        );
    rep("$dest_addr <== $src_addr ($msgtext)");
	if(!$resp || $resp->{status}!=0) {
		$dbh->do("UPDATE `pan_message_out` SET msgo_lastretry=UNIX_TIMESTAMP(), msgo_lasterror= ?  WHERE msgo_id= ?", undef, explain_status($resp->{status}) , $msgo_id );
		rep("failed to send $msgo_id (Status: ".explain_status($resp->{status}).")");

		if($resp->{status}==11 || $resp->{status}==10){
			rep("Message #$msgo_id will not be sent again");
			$dbh->do("UPDATE `pan_message_out` SET msgo_sendtime=UNIX_TIMESTAMP(), msgo_smsc_id= ?  WHERE msgo_id= ?", undef, $resp->{message_id} , $msgo_id );
		}
		return 0;
	}else{
		$dbh->do("UPDATE `pan_message_out` SET msgo_sendtime=UNIX_TIMESTAMP(), msgo_smsc_id= ?  WHERE msgo_id= ?", undef, $resp->{message_id} , $msgo_id );
		return 1;
	}
}



sub decode
{
    my $date=$_[0];
    my %dd;
    $date=~ /(^.*?)\x00(.)(.)(.*?)\x00(.)(.)(.*?)\x00(.)(.)(.)(.*?)\x00(.*?)\x00(.)(.)(.)(.)(.)(.*$)/;
    $dd->{service_type}=$1;
    $dd->{source_addr_ton}=$2;
    $dd->{source_addr_npi}=$3;
    $dd->{source_addr}=$4;
    $dd->{dest_addr_ton}=$5;
    $dd->{dest_addr_npi}=$6;
    $dd->{destination_addr}=$7;
    $dd->{esm_class}=$8;
    $dd->{protocol_id}=$9;
    $dd->{priority_flag}=$10;
    $dd->{schedule_delivery_time}=$11;
    $dd->{validity_period}=$12;
    $dd->{registered_delivery}=$13;
    $dd->{replace_if_present_flag}=$14;
    $dd->{data_coding}=$15;
    $dd->{sm_default_msg_id}=$16;
    $dd->{length_short_message}=$17;
    $dd->{short_message}=$18;
    #check if in unicode
    #if($dd->{data_coding} == 0x08){

    #}
    return $dd;
}

sub processQueue
{
	#temporarily disable timer
	setitimer(ITIMER_REAL, 0);

    $smpp_t->enquire_link();

	#return;
	# ��������� �������� ��������� � ���������� ��
    my $sth1 = $dbh->prepare("SELECT  msgi_id,msgi_recvdtime,msgi_from,msgi_body,sn_number,msgi_seqnum FROM pan_message_in WHERE  `msgi_processtime`='0' ");

    my $inresult = $sth1->execute();
    if( ('0E0' eq $inresult ) ){
		#rep("Inbox is empty.");
	}else{
		rep("Processing incoming messages ");
		while(my ($msgi_id,$msgi_recvdtime,$msgi_from,$msgi_body,$sn_number,$msgi_seqnum) = $sth1->fetchrow_array()){
			rep("ID: $msgi_id, RECIEVED: $msgi_recvdtime, FROM: $msgi_from, TO: $sn_number, BODY: $msgi_body, SEQnum: $msgi_seqnum");
            my %sms = (
               "source_addr"  => $msgi_from,
               "short_message" => $msgi_body,
               "destination_addr"  => $sn_number,
               "seq" => $msgi_seqnum,
			   "msgi_id" => $msgi_id
              );
			#����� � ��������?
			if ($msgi_body =~ m/^id:([a-z0-9+-]+) sub:([0-9]{1,3}) dlvrd:([0-9]{1,3}) submit date:([0-9]{10}) done date:([0-9]{10}) stat:([a-z]{7})/i) {
				#mark message with id $1 delivery status
				$dbh->do("UPDATE `pan_message_out` SET `msgo_status`='$6' WHERE `msgo_smsc_id`= ?", undef, $1);
				$dbh->do("UPDATE `pan_message_in` SET `msgi_isreport`='1' WHERE `msgi_id`= ?", undef, $msgi_id);
			}else{ #���������� ����������
				ruleProcessor(%sms);
			}
			$dbh->do("UPDATE `pan_message_in` SET `msgi_processtime`=UNIX_TIMESTAMP() WHERE `msgi_id`= ?", undef, $msgi_id);
		}

	}
	$sth1->finish ();


	#���� �� �������������� ���������
	#rep("Checking outbox...");
	my $sth = $dbh->prepare("SELECT msgo_id,msgo_body,msgo_to,msgo_from,msgo_reqstatus FROM `pan_message_out`
								WHERE  msgo_sendtime='0' AND (msgo_lastretry='0' OR msgo_lastretry<UNIX_TIMESTAMP()-300) ");

	my $exresult = $sth->execute();
	if( ('0E0' eq $exresult ) ){
		#rep("Outbox is empty.");
	}else{
		rep("Sending messages from outbox");
		while(my ($msgo_id,$msgo_body,$msgo_to,$msgo_from,$msgo_reqstatus) = $sth->fetchrow_array ()){
		#���������� ���������
    		Send($msgo_to,$msgo_body,$msgo_from,$msgo_id,$msgo_reqstatus);
		}
	}
	$sth->finish ();
	#RESTORE TIMER
	setitimer(ITIMER_REAL, 1);
}

sub queueMsg
{
	my ($msgo_text,$msgo_to,$msgo_from,$msgi_id,$reqstatus) = @_;

	$dbh->do("INSERT INTO `pan_message_out` (msgo_body,msgo_gentime,msgo_from,msgo_to,msgo_reqstatus) VALUES ( ?, UNIX_TIMESTAMP(), ?, ? )",
					undef,	$msgo_text , $msgo_from , $msgo_to, $reqstatus );
}

sub inboxQueueMsg
{
	my ($msg_text,$dest_addr,$msgi_id) = @_;

	$dbh->do("INSERT INTO `pan_message_in` (msgi_text,msgi_recieved,msgi_from,dest_addr) ".
				"VALUES ( ?, UNIX_TIMESTAMP(), ? )",
				undef,	$msg_text, $dest_addr);

}

sub mainloop(){
	$SIG{ALRM} = sub { &processQueue; };
	setitimer(ITIMER_REAL, 1);

	my $read_set = new IO::Select($smpp_t);

	while(1){
	#rep("about to can_read()");
		if( $read_set->can_read (1)){
			#rep("passed can_read  ");
			$read_set->add($smpp_t);

			my $pdu = $smpp_t->read_pdu();
		#print "got cmd = ".$pdu->{cmd}."\n";

			switch($pdu->{cmd}){
			case Net::SMPPSSL::CMD_deliver_sm {
				$smpp_t->deliver_sm_resp(seq=>$pdu->{seq},message_id=>"\x00");
				my $sms = &decode($pdu->{data});
				rep( ($sms->{source_addr} or "")." ==> \"".($sms->{short_message}  or "")."\"");
				last if !$sms->{source_addr};
				#register this SMS in the inbox
				$dbh->do("INSERT INTO `pan_message_in` (msgi_recvdtime,msgi_from,msgi_body,sn_number,msgi_seqnum)".
							" VALUES (UNIX_TIMESTAMP(), '".$sms->{source_addr}."' ,".$dbh->quote($sms->{short_message})." ,'".$sms->{destination_addr}."' , '".$pdu->{seq}."' )" );
			}
			case Net::SMPPSSL::CMD_unbind {
				rep("Got unbind cmd. Breaking loop");
				$smpp_t->unbind_resp();
				return;
			}
			case Net::SMPPSSL::CMD_enquire_link{
				rep("Got CMD_enquire_link");
				$smpp_t->enquire_link_resp();
			}
			case Net::SMPPSSL::CMD_enquire_link_resp{
				rep("Got CMD_enquire_link_resp");
				#$smpp_t->enquire_link_resp();
			}
			case Net::SMPPSSL::CMD_alert_notification{
				rep("Got CMD_alert_notification");
			}
			case ""{
				rep("Socket seems to be closed (got empty cmd)");
				return;
			}
			case "0"{
				rep("Socket seems to be closed (got zero cmd)");
				return;
			}
			else { rep("unexpected pdu cmd #".$pdu->{cmd}); }
			}
		}
	}
}

sub ruleProcessor{
    my (%msg) = @_;
    #        %msg = (
    #           "source_addr"
    #           "short_message"
    #           "destination_addr"
    #           "msg_id"
    #          );

    %RULES_INPUT = %msg;

	#predefine some constanst
	my $currentDay = (qw(Mon Tue Wed Thu Fri Sat Sun))[(gmtime)[6]];
    my $rq = $dbh->prepare("SELECT  rule_id,rule_name FROM pan_rules WHERE `rule_enabled`!='0' ORDER BY rule_order ASC");
    my $rulesres = $rq->execute();
    if( ('0E0' eq $rulesres ) ){
		rep("No rules for now");
	}else{
        #rep("RULES: found $rulesres active rules");
        while(my ($rule_id,$rule_name) = $rq->fetchrow_array()){
			#get all rule conditions in right order and try to apply them
			my $rule_true = 1;
            my $rcq = $dbh->prepare("SELECT rc_key , rc_relativity , rc_val  FROM pan_rule_conditions WHERE `rule_id`='$rule_id' ORDER BY rc_id ASC");
            my $rcres = $rcq->execute();
			#now check all conditions and try to make $rule_true  to be = 0
			if('0E0' ne $rcres ){
				while(my ($rc_key,$rc_relativity,$rc_val) = $rcq->fetchrow_array()){
				    my $leftside = '';
					#determine leftside
					switch($rc_key){
					    case "SourceAddr" 		{ $leftside = $msg{source_addr}; }
					    case "Body" 			{ $leftside = $msg{short_message}; }
					    case "DestAddr" 		{ $leftside = $msg{destination_addr}; }
					    case "MessageSize" 		{ $leftside = length($msg{short_message}); }
#					    case "TimeOfDay" 		{ }
#					    case "CurrentDate" 		{ }
					    case "CurrentDay" 		{ $leftside = $currentDay; }
					}
					#analyse them
     				switch($rc_relativity){
						case "ne"{ $rule_true = 0 if($leftside eq $rc_val);}
						case "eq"{ $rule_true = 0 if($leftside ne $rc_val);}
						case "lt"{ $rule_true = 0 if($leftside gt $rc_val);}
						case "gt"{ $rule_true = 0 if($leftside lt $rc_val);}
						case "in"{
							my @splitted = split(/,/, $rc_val);
							my $inlist = 0;
							foreach (@splitted) {
							    $inlist = 1 if ($_ eq $leftside);
							}
                            $rule_true = 0 if($inlist == 0);
						}
						case "notin"{
                            my @splitted = split(/,/, $rc_val);
							my $inlist = 0;
							foreach (@splitted) {
							    $inlist = 1 if ($_ eq $leftside);
							}
                            $rule_true = 0 if($inlist != 0);
						}
					}
					#rep("RULE[$rule_name] TRUTH is ($rule_true) after ('$leftside' $rc_relativity '$rc_val')");
				}
			} else{
				#rep("RULE[$rule_name] Has No conditions");
			}
			# and then - if $rule_true still is true - apply rule actions
			if($rule_true == 1){
                rep("RULE[$rule_name] Would be applied");
				#fetch actions
				my $raq = $dbh->prepare("SELECT ra_action , ra_atribute, ra_id  FROM pan_rule_actions WHERE `rule_id`='$rule_id' ORDER BY ra_id ASC");
            	my $rcres = $raq->execute();
            	while(my ($ra_action, $ra_atribute,$ra_id ) = $raq->fetchrow_array()){
	                switch($ra_action){
					    case "ForwardTo" {
					        my $forwarding = "Forwarded message from $msg{source_addr}:\n$msg{short_message}";
					        rep("RULE[$rule_name] Forwards this Message to $ra_atribute");
					        queueMsg($forwarding, $ra_atribute, $msg{msgi_id});
						}
					    case "MirrorTo" {
					        rep("RULE[$rule_name] Mirrors this Message to $ra_atribute");
					        queueMsg($msg{short_message}, $ra_atribute, $msg{msgi_id});
						}
					    case "StopProcessing" {
					        rep("RULE[$rule_name] Stopped Processing of this Message");
					        return;
						}
					    case "Discard" {
					        rep("RULE[$rule_name] would use Discard Message. NOT IMPLEMENTED");
						}
					    case "ReplyWith"{
					        queueMsg($ra_atribute, $msg{source_addr}, $msg{msgi_id});
						}
	                    case "Execute"{
	                        rep("RULE[$rule_name] uses Built-in Function[$ra_atribute].");
							eval("$ra_atribute(\%msg);");
							if($@ ne ""){
								rep("RULE[$rule_name] failed to Execute Built-in Function \"$ra_atribute\" due to following error: $@");
							}
						}
	                    case "ExternalFilter" {
                        	rep("RULE[$rule_name] uses ExternalFilter[$ra_atribute].");
                            my $EFerr = '';
							my $efq = $dbh->prepare("SELECT pl_id, pl_path, pl_isactive, pl_timeout  FROM pan_plugins WHERE `pl_name`='$ra_atribute'");
            				my $efres = $efq->execute();
            				if('0E0' eq $efres ){
                    			$EFerr = "Filter not found.";
							}else{
	                            my ($pl_id, $pl_path,$pl_isactive,$pl_timeout ) = $efq->fetchrow_array();
	                            if($pl_isactive eq 0){
                                    $EFerr = "Filter is disabled.";
								}else{
		                            unless ($EFreturn = do "$ROOTDIR/$pl_path"){
		                                #$EFerr = " ";
										$EFerr .= " <couldn't parse file '$pl_path': $@> " 	if $@;
									    $EFerr .= " <$pl_path: $!> "    					unless defined $EFreturn;
									    $EFerr .= " <couldn't run file '$pl_path'> "       	unless $EFreturn;
									}
									rep ("$EFreturn");
								}
							}
							rep("RULE[$rule_name] failed to use External Filter \"$ra_atribute\" due to following error: $EFerr")
								    if $EFerr ne '';
						}
	                    case "WriteToLog"{
							rep($ra_atribute);
						}
					}
				}
			}
		}
	}
}


;
