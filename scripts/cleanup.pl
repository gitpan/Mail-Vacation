#!/usr/bin/perl
# 
# $Id:
# mail vacation cleanup script - crontab entry each monday:
# 
# 5 4 * * mon /home/octo/Vacation/cleanup.pl
#
use Mail::Vacation;
use strict;

my $o_vac = Mail::Vacation->new('/home/octo/Vacation/vacation.conf');

if ($o_vac) {
	if ($o_vac->start()) {
		$o_vac->cleanup(); 
		$o_vac->finish();
	}
}

exit;

