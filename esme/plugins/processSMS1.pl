#!/usr/bin/perl

#processSMS1
my %msg = %RULES_INPUT; #originally: my (%msg) = @_;



rep ("PROCESSING WITH processSMS1($msg{msgi_id})");
return 0 if !defined $msg{source_addr};

my $mcnt = trim($msg{short_message});


$sth = $dbh->prepare("SELECT cnt_id,cnt_code FROM `if_content` WHERE  cnt_code='$mcnt'");

if(('0E0' eq $sth->execute() ) or $msg{short_message} eq ""){
	queueMsg("Invalid command (".$msg{short_message}.")", $msg{source_addr}, $msg{msgi_id});
	#Send($msg->{source_addr},"Net takogo koda (".$msg->{short_message}.")");
	return;
}

#make unique code
my ($cnt_id, $cnt_code) = $sth->fetchrow_array ();
my $code;
do{
	$code = gen_string(10);
}while(
 	1 ne $dbh->do("INSERT IGNORE INTO `esme_contentlink` (`link_key`, `cnt_id`, `link_mktime`,`dest_addr`,`msgi_id`) VALUES( '$code' , '$cnt_id' ,UNIX_TIMESTAMP(), '$msg{source_addr}' ,'$msg{msgi_id}')",
     	undef)
);
	$sth->finish ();


my $APPENDIX = '';
my $ch  = $dbh->prepare("SELECT esme_linksms_end FROM `if_mainconf`");
if('0E0' ne $ch->execute() ){
 	($APPENDIX) = $ch->fetchrow_array ();
}
$ch->finish ();

$reply = "http://".$HTTP_DOM."/A/".$code."\n$APPENDIX";
# do reply
queueMsg($reply, $msg{source_addr}, $msg{msgi_id});

return 1;
