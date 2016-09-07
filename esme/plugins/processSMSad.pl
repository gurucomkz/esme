#!/usr/bin/perl


#processSMSad
my %msg = %RULES_INPUT; #originally: my (%msg) = @_;

rep ("PROCESSING WITH processSMSad($msg{msgi_id})");
return 0 if !defined $msg{source_addr};

#make unique code
my $code;
do{
	$code = gen_string(10);
}while(
	1 ne $dbh->do("INSERT IGNORE INTO `if_advertisement_codes` (`adv_code`, `adv_code_date`, `adv_code_tel`,`msgi_id`) VALUES( '$code' , UNIX_TIMESTAMP(), '$msg{source_addr}', '$msg{msgi_id}' )",
		undef)
);

$reply = "$code -- Use this code SMS @ www.example.com";
# reply
queueMsg($reply,$msg{source_addr},$msg{msgi_id});

return 1;
