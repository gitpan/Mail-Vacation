#!/usr/bin/perl -wW
#
# test script for Mail::Vacation::LDAP
# $Id: $
#

use Data::Dumper;
use Date::Manip;
use Test::More tests => 11;
use strict;
BEGIN { use_ok('Mail::Vacation::LDAP') };

my $config  = './conf/ldap.conf';
my @toclean = ();

my $o_vac = Mail::Vacation::LDAP->new($config);
ok(ref($o_vac), 'new') or diag("is configfile($config) ok? and is ldap server running?");

# config
my $server 		= $o_vac->_config('server');
my $sendmail	= $o_vac->_config('sendmail');
my $testflag 	= $o_vac->_config('testflag');
my $repliedto	= $o_vac->_config('repliedtodbdir');
my %attr		= $o_vac->_config->hash('attributes');
my $start 		= $attr{start}   || '';
my $end 		= $attr{end}     || '';
my $forward		= $attr{forward} || '';
my $message 	= $attr{message} || '';
my $alias		= $attr{alias}   || '';
{
	my $i_err = 0;

	my %env				= $o_vac->_config->hash('env');
	$ENV{$env{user}}    = 'vacation';
	$ENV{$env{local}}   = 'vacation.usr';
	$ENV{$env{domain}}  = 'rfi.net';
	$ENV{$env{extension}}  = 'Vacation User';

	$sendmail	=~ /\w+/o or $i_err++, diag("missing sendmail command($sendmail)?");
	$repliedto	=~ /\w+/o or $i_err++, diag("missing repliedtodbdir($repliedto)?");
	$server   	=~ /\w+/o or $i_err++, diag("missing server($server)?");
	$testflag	== 1      or $i_err++, diag("testflag($testflag) must be set for testing");
	$start		=~ /\w+/o or $i_err++, diag("missing start key($start)?"); 
	$end		=~ /\w+/o or $i_err++, diag("missing end key($end)?");
	$message	=~ /\w+/o or $i_err++, diag("missing message key($message)?");
	$alias		=~ /\w+/o or $i_err++, diag("missing mail alias key($alias)?");

	ok($i_err == 0, '_config');
}

my $o_start = $o_vac->start();
ok(1, 'start');
unless (ref($o_start)) {
	diag("no ldap server($server)");
	diag("if you really want this to work, you need an ldap server to connect to!");
}

SKIP: {
	skip "unless ldap server", 7 unless ref($o_start);

	my $o_ldap = $o_vac->_ldap;
	ok(ref($o_ldap), 'o_ldap');

# _retrieve
	{
		my $i_err = 0;

		my @x_ret = $o_vac->_retrieve('filter' => "($$ x cnx = ?... \& * = \\ - never_heard of-it [ x+\/!] )");
		unless (@x_ret == 0) {
			$i_err++; diag('no retrieve');
		}

		my @h_ret = $o_vac->_retrieve('filter' => '(cn=*)');
		unless (@h_ret >= 3) {
			$i_err++; diag('retrieve (cn=*)');
		}

		my $i_hcnt = my ($h_ret) = $o_vac->_retrieve('filter' => '(cn=verreiser)');
		unless ($i_hcnt == 1 && ref($h_ret) eq 'HASH') {
			$i_err++; diag("cn=verreiser i_hcnt($i_hcnt): ".Dumper($h_ret));
		}

		ok($i_err == 0, '_retrieve');
	}

	my $verreiser = q|
	To: "on holiday" <verreiser@rfi.net>
	From: oneelse@rfi.net
	|;
	push(@toclean, 'oneelse@rfi.net');
	my $o_verreiser = $o_vac->_setup_int($verreiser);
	ok(ref($o_verreiser), '_setup_int');

# _onvacation 
	{
# rjsf - with/without forward/message
#
		my $i_err = 0;
		my $h_testok = { 
			$start	=> &DateCalc('now', '- 50 days'),
			$end  	=> &DateCalc('now', '+ 50 days'),
			$message=> "ldap test message $$",
		};
		my ($from, $msg, $a_fwd) = $o_vac->_onvacation($h_testok);
		unless ($msg eq "ldap test message $$") { 
			$i_err++; diag("_onvacation failed with msg($msg)");
		}

		my $h_testnomsg = { 
			$start	=> &DateCalc('now', '- 50 days'),
			$end  	=> &DateCalc('now', '+ 50 days'),
			# $message=> "ldap test message $$",
			$forward=> 'x@y.z',
		};
		my ($nofrom, $nomsg, $a_nfwd) = $o_vac->_onvacation($h_testnomsg);
		unless ($nomsg eq "") { 
			$i_err++; diag("testnomsg failed with nomsg($nomsg)");
		}

		my $h_testout = { 
			$start	=> &DateCalc('now', '- 50 days'),
			$end  	=> &DateCalc('now', '- 17 days'),
			$message=> "ldap test message $$",
		};
		my ($ofrom, $out, $a_ofwd) = $o_vac->_onvacation($h_testout);
		unless ($out eq "") { 
			$i_err++; diag("testout failed with out($out)");
		}

		ok($i_err == 0, '_onvacation');
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
# $DB::single=2; # rjsf one should fail - one should succeed
		my $h_test = {
			'start'	=> 'yesterday',
			# 'now'	=> '',
			# 'end'	=> 'tomorrow',
			'message'	=> 'yuhu',
			'forward'	=> 'x@y.z',
		};
		my $o_proc = $o_vac->process($o_pgood, $h_test);
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

	my $o_finish = $o_vac->finish();
	ok(ref($o_finish), 'finish');

} # skip

#

