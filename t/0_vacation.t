#!/usr/bin/perl -wW
#
# test script for Mail::Vacation
# $Id: $
#

use Data::Dumper;
use Date::Manip;
use Fcntl 'O_RDONLY';
use Test::More tests => 28;
use Tie::File;
use strict;
BEGIN { use_ok('Mail::Vacation') };

my $config   = './conf/vacation.conf';
my $syslog   = '/var/log/messages';
my $tmpdir   = '/tmp';
my $testfrom = 'test@rfi.net';
my $num      = 5; # log entries which are counted: nof$num
my @toclean  = ($testfrom);

SKIP: {
	skip "unless $syslog readable", 6 unless -r $syslog; 

	my $o_pre = tie my @pre, 'Tie::File', $syslog, 'mode' => O_RDONLY;
	my $pre   = $#pre;
	ok(ref($o_pre), "pre syslog($pre)") or diag("problem reading $syslog $!");
	undef $o_pre;
	untie @pre;
	
	my $debug = $Mail::Vacation::DEBUG = 0;
	Mail::Vacation::_xlog(bless({}, 'Mail::Vacation'), "$$ 1of$num _xlog always($debug)");
	Mail::Vacation::_log( bless({}, 'Mail::Vacation'), "$$ 2of$num _log silent($debug)"); # <-
	$debug = $Mail::Vacation::DEBUG = 1;
	Mail::Vacation::_xlog(bless({}, 'Mail::Vacation'), "$$ 3of$num _xlog always($debug)");
	Mail::Vacation::_log( bless({}, 'Mail::Vacation'), "$$ 4of$num _log if debug($debug)");
	my $o_err = Mail::Vacation::_error(bless({}, 'Mail::Vacation'), "$$ 5of$num _error msg");

	my $o_post = tie my @post, 'Tie::File', $syslog, 'mode' => O_RDONLY;
	ok(ref($o_post), "post syslog($#post)");
	my @log = @post[$#post-($#post-$pre) .. $#post];
	my $log = join("\n", @log);
	undef $o_post;
	untie @post;

	ok($log =~ /$$ 1of$num _xlog/ && $log =~ /$$ 3of$num _xlog/, '_xlog');
	ok($log !~ /$$ 2of$num _log/  && $log =~ /$$ 4of$num _log/, '_log');
	ok($log =~ /$$ 5of$num _error msg/ && !ref($o_err), '_error');
}

# _configure
{
	my $i_err = 0;
	
	my $okconfig = Mail::Vacation::_configure(bless({}, 'Mail::Vacation'), $config);
	unless (ref($okconfig)) { 
		$i_err++; diag("_configure file($config) problem?");
	}

	ok($i_err == 0, '_configure');
}

my $o_vac = Mail::Vacation->new($config);
ok(ref($o_vac), 'new');

my $o_done = $o_vac->start;
ok(ref($o_done), 'start');

# _config
{
	my $i_err = 0;

	my $sendmail 		= $o_vac->_config('sendmail');
	my $repliedtodbdir 	= $o_vac->_config('repliedtodbdir');
	my $expirytime 		= $o_vac->_config('expirytime');
	my $homedir 		= $o_vac->_config('homedir');

	my %env				= $o_vac->_config->hash('env');
	$ENV{$env{user}}    = 'vacation';
	$ENV{$env{local}}   = 'vacation.usr';
	$ENV{$env{domain}}  = 'rfi.net';
	$ENV{$env{extension}}  = 'Vacation User';

	$sendmail		=~ /\w+/o or $i_err++, diag("missing sendmail command($sendmail)?");
	$expirytime		=~ /\w+/o or $i_err++, diag("missing expiry time($expirytime)?");
	-d $repliedtodbdir	or $i_err++, diag("invalid repliedtodbdir($repliedtodbdir)");
	-d $homedir 		or $i_err++, diag("invalid home directory($homedir)");

	ok($i_err == 0, '_config');
}

my $dump = $o_vac->_dump;
ok($dump =~ /\$VAR/ && $dump =~ /Mail::Vacation/, '_dump');

my @emsgs = $o_vac->messages;
$o_vac->_error('err1'); $o_vac->_error('err2'); $o_vac->_error('err3');
my @xmsgs = $o_vac->messages;
ok(@emsgs == 0 && @xmsgs == 3 && $xmsgs[0] =~ /^err1$/o && $xmsgs[2] =~ /^err3$/o, 'messages');

my $isok = $o_vac->isok;
ok($isok == 0, 'isok');

# _mailfrom 
{
	my $i_err = 0;
	my %orig = %ENV;

	my %env = $o_vac->_config->hash('env');
	my $local     = $ENV{$env{local}}     = 'LocaL';
	my $domain    = $ENV{$env{domain}}    = 'DomaiN';
	my $extension = $ENV{$env{extension}} = 'ExtensioN';
	my $mailfrom  = $o_vac->_mailfrom;
	$mailfrom =~ /^"$extension"\s\<$local\@$domain\>$/o or $i_err++, diag("_mailfrom env: ".Dumper(\%env));

	%ENV = %orig;
	ok($i_err == 0, '_mailfrom') or diag("_mailfrom -> $mailfrom failed");
}

$o_vac = $o_vac->_reset;
ok($o_vac->isok == 1 && $o_vac->messages == 0 && $o_vac->{_errors} == 0, '_reset');
# diag("isok: ".$o_vac->isok." msgs: ".$o_vac->messages." errs: ".$o_vac->{_errors});

# _track
{
	my $i_err = 0;

	my ($to, @cc) = $o_vac->_track("\"xxx \" <$testfrom>", ['"Mail::Vacation" <vacation@rfi.net>']);
	($to =~ /^vacation\@rfi.net$/o && @cc == 0) 
		or $i_err++, diag("_track clean: to($to) cc(@cc)");

	($to, @cc) = $o_vac->_track("$testfrom", ['"Mail::Vacation" <xvacation@rfi.net>']);
	($to =~ /^xvacation\@rfi.net$/o && @cc == 0)
		or $i_err++, diag("_track second entry: to($to) cc(@cc)");

	($to, @cc) = $o_vac->_track("\"Test Cc \" <$testfrom>", [
		'test2@rfi.net ', 'XYZ vacation@rfi.net ', 'Xvacation@rfi.net ', 
		'Vacation@RFI.net', '"ignore this" <vacation@rfi.net>', '" " VACATION@rfi.net',
		' cc@rfi.net',
		]
	);
	($to =~ /^test2\@rfi.net$/o && @cc == 1 && $cc[0] =~ /^cc\@rfi.net$/o) 
		or $i_err++, diag("_track ccs: to($to) cc(@cc)");

	ok($i_err == 0, '_track') or diag("_track failed");
}

my $msgid = $o_vac->_get_rand_msgid;
ok($msgid =~ /\w+\@\w+/o, '_get_rand_msgid');

# _invacation
{
	my $i_in  = $o_vac->_invacation({'start'=>'20010102', 'now'=>'20020102', 'end'=>'20020103'});
	my $i_nonw= $o_vac->_invacation({'start'=>'20020104', 'now'=>'',         'END'=>''});
	my $i_out = $o_vac->_invacation({'start'=>'19990102', 'now'=>'today',	 'end'=>'today - 1 day'});
	my $i_char= $o_vac->_invacation({'START'=>'zvckljsd', 'now'=>'20020104', 'end'=>'20020103'});
	my $i_num = $o_vac->_invacation({'start'=>'00000000', 'Now'=>'20020104', 'end'=>'20020103'});
	my $i_nofr= $o_vac->_invacation({'start'=>'',         'now'=>'20020104', 'END'=>'20020103'});
	my $i_noto= $o_vac->_invacation({'start'=>'20020104', 'now'=>'20020103', 'end'=>''});
	my $i_nix = $o_vac->_invacation([]);
	ok(
	$i_in == 1  && $i_nonw == 1 && 
	$i_out == 0 && $i_char == 0 && $i_num == 0 && $i_nofr == 0 && $i_noto == 0 && $i_nix == 0, 
		'_invacation') or diag(
		"in($i_in) nonw($i_nonw) \nout($i_out) char($i_char) i_num($i_num) i_nofr($i_nofr) i_noto($i_noto) i_nix($i_nix)"
	);
}

# _retrieve
{
	my $i_err = 0;

	my @xret = $o_vac->_retrieve('xfilter' => "$$ - x+. never heard of them!? :-\/");
	@xret == 0 or $i_err++, diag("xret(@xret)");

	my ($h_msg) = $o_vac->_retrieve('filter' => '*');
	$$h_msg{message} eq 'unimplemented' or $i_err++, diag("dodgy message($$h_msg{message})");

	ok($i_err == 0, '_retrieve'); 
}

my $from = 'fromsomeone@rfi.net';
my $to   = '"on holiday" <vacation@rfi.net>';
my $list = 'mailing-list@rfi.net';
my $loop = qq|
To: $to
From: $from
X-Mail-Vacation: our stamp 
|;
my $good = qq|
To: good.user\@rfi.net
From: $from
|;
my $noto = qq|
From: $from
|;
my $nofrom = qq|
To: $to
|;
my $maillist = qq|
To: $to
From: $list
X-Mailing-List: mailing list sig.
|;
my $vacation = qq|
To: $to
From: oneelse\@rfi.net
|;
push(@toclean, $from, $list, 'oneelse@rfi.net');

my $o_loop    = $o_vac->_setup_int($loop);
my $o_good    = $o_vac->_setup_int($good);
my $o_noto    = $o_vac->_setup_int($noto);
my $o_nofrom  = $o_vac->_setup_int($nofrom);
my $o_list    = $o_vac->_setup_int($maillist);
my $o_vacmail = $o_vac->_setup_int($vacation);

# _looks_ok 
{
	my $i_err = 0;

	ref($o_loop)      or $i_err++, diag('_setup_int anti-loop');
	ref($o_good)      or $i_err++, diag('_setup_int good');
	# ref($o_noto)    or $i_err++, diag('_setup_int noto');
	# ref($o_nofrom)  or $i_err++, diag('_setup_int nofrom ');
	ref($o_list)      or $i_err++, diag('_setup_int list');
	ref($o_vacmail)   or $i_err++, diag('_setup_int vacmail');

	ok($i_err == 0, '_setup_int');
}

# _int2user
{
	my $i_err = 0;

	my $vacuser = $o_vac->_int2user($o_vacmail);
	$vacuser eq 'vacation' or $i_err++, diag("vacuser($vacuser)");

	my $gooduser = $o_vac->_int2user($o_good);
	$gooduser eq 'good.user' or $i_err++, diag("gooduser($gooduser)");
	
	ok($i_err == 0, '_int2user');
}

# _onvacation
{
	my $i_err = 0;
	my ($xfrom, $xmsg, $a_xfwd) = $o_vac->_onvacation($o_good);
	$xmsg or $i_err++, diag("o_good($xmsg)");

	my ($from, $msg,  $a_fwd) = $o_vac->_onvacation($o_vacmail);
	$msg eq "default vacation msg\n" or $i_err++, diag("invalid vacation message($msg)");

	ok($i_err == 0, '_onvacation'); 
}

# _looks_ok 
{
	my $i_err = 0;

	my $o_okloop = $o_vac->_looks_ok($o_loop);
	!ref($o_okloop) or $i_err++, diag("_looks_ok anti-loop $o_okloop");

	my $o_oklist = $o_vac->_looks_ok($o_list);
	!ref($o_oklist) or $i_err++, diag("_looks_ok anti-mailing-list $o_oklist");

	my $o_ok = $o_vac->_looks_ok($o_good);
	ref($o_ok) or $i_err++, diag('_looks_ok plain');

	ok($i_err == 0, '_looks_ok'); 
}

# _reply
{
	my $i_err = 0;

	my $o_repnoto = $o_vac->_reply($o_noto, "repmsg noto\n");
	if ($o_repnoto) {
		$i_err++; diag("failed noto _reply");
	}

	my $o_repnomsg = $o_vac->_reply($o_good, '');
	if ($o_repnoto) {
		$i_err++; diag("failed nomsg _reply");
	}

my $vgood = qq|
To: local-target-address\@rfi.net 
From: original-sender\@rfi.net
|;
	push(@toclean, 'original-sender@rfi.net');

	my $from = $o_vac->_mailfrom();
	my $o_vgood = $o_vac->_setup_int($vgood);
	my $o_rep   = $o_vac->_reply($o_vgood, "repmsg vgood\n", $from);
	unless (ref($o_rep)) {
		$i_err++; diag("failed vgood _reply($o_rep)");
	}

	ok($i_err == 0, '_reply'); 
}

# _forward
{
	my $i_err = 0;

	my $fgood = qq|
To: local-target-address\@rfi.net 
From: original-sender$$-$$\@rfi.net
|;
	push(@toclean, "original-sender$$-$$\@rfi.net");
	my $o_fgood = $o_vac->_setup_int($fgood);

	my $testfwd = 'hols@rfi.net';
	push(@toclean, $testfwd);
	my $o_fwd = $o_vac->_forward($o_fgood, [$testfwd]);
	unless ($o_fwd) {
		$i_err++; diag("failed good _forward");
	}

	ok($i_err == 0, '_forward'); 
}

# process 
{
	my $i_err = 0;

	my $pgood = qq|
To: local-target-address$$\@rfi.net 
From: original-sender$$\@rfi.net
|;
	push(@toclean, "original-sender$$\@rfi.net");
	my $o_pgood = $o_vac->_setup_int($pgood);
	my $o_proc = $o_vac->process($o_pgood);
	unless (ref($o_proc)) {
		$i_err++; diag("failed pgood process");
	}

	ok($i_err == 0, 'process');
}

# cleanup
{
	my $i_err = 0;

	my $now = &DateCalc('now', '+ 1 day');
	my $o_cleanup = $o_vac->cleanup($now, \@toclean);
	unless (ref($o_cleanup)) {
		$i_err++; diag("cleanup($now) failed($o_cleanup)");	
	}

	ok($i_err == 0, 'cleanup'); 
}

my $o_fin = $o_vac->finish;
ok(ref($o_fin), 'finish');

#
