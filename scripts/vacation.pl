#!/usr/bin/perl
# 
# mail vacation - new() points to config file
# $Id:
#
use Mail::Vacation;
use Mail::Internet;
use strict;

my $o_vac = Mail::Vacation->new('/home/octo/Vacation/ldap.conf');
my $o_int = Mail::Internet->new(\*STDIN);

if ($o_vac && $o_int) {
	if ($o_vac->start()) {
		$o_vac->process($o_int); 
		$o_vac->finish();
	}
}

exit(0); # always succeed

