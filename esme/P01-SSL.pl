#!/usr/bin/perl -w
use Net::SMPPSSL;
use Digest::MD5;
use Switch;
use DBI;
use Fcntl ':flock'; # import LOCK_* constants
use Text::Iconv;

$ROOTDIR = "/var/www/html/esme/";
    open(PIDFILE, ">>$ROOTDIR/lockfile")
            or die "Can't open lockfile: $!";
    flock(PIDFILE,LOCK_EX | LOCK_NB) or die("Lockfile Busy");



#use File::chdir;
#$CWD = "/home/gvozdkz/public_html/phpsmse/";
$PLUGIN_DIR = "$ROOTDIR/plugins/";
print "Plugins directory not set" if(!$PLUGIN_DIR);


$SIG{HUP} = 'IGNORE';

do "$ROOTDIR/esmeroutines-SSL.pl"; # все функции ESME

$dbh = &connect; # соединяемся с БД
die(0) if(!$dbh);
$dbh->do("SET NAMES cp1251", undef);
$dbh->do("SET character_set_client='cp1251'", undef);
$dbh->do("SET character_set_results='cp1251'", undef);
$dbh->do("SET character_set_connection='cp1251'", undef);
$dbh->do("SET character_set_results='cp1251'", undef);

print "Connecting...\n";
&connect_transport; # соединяемся с SMSC
print "\nConnected\n";

# MAINLOOP HERE
&mainloop;          # работать, негры!

# отключаемся от сервера

&disconnect_transport;
flock(PIDFILE,LOCK_UN);
exit (0);


