#!/usr/bin/perl -w

=head1 NAME

ldap.cgi - vacation web update

=head1 USAGE

login with cn=..., then modify vacation attributes

N.B. initial version modifies sn attribute only

second <hr> indicates succesful modification to LDAP database

=cut

use strict;
use lib qw(/home/octo/);
use CGI qw(:standard *table);
use CGI::Carp qw/fatalsToBrowser/;
use Data::Dumper;
use Date::Manip;
use Mail::Vacation::LDAP;
use URI::Escape;

my $debug = 1;

my $cgi = new CGI;
my $relative_url  = $cgi->url(-relative=>1);
print $cgi->header;
my $reset   = $cgi->reset;
my $submit  = $cgi->submit(
	-'name' => 'login', -'value' => 'Login',
);

my $xreq = $cgi->param('request') || 'dn'; # /dn|<entries>|(user|group)ids/
my $xdn  = $cgi->param('dn')  || ''; # or modify

my $o_vac = Mail::Vacation::LDAP->new('/home/octo/Mail/conf/ldap.conf');
print $cgi->start_html(ref($o_vac).' '.$xreq);
my $attrs = ['cn', 'UNIX_UID', 'givenName', 'sn', 'MailAlias'];

unless ($xdn =~ /\w+/o) { # login
	print($cgi->h1(ref($o_vac).' '.($xdn)));
	my $cn      = $cgi->textfield(
		-'name' => 'cn', -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => '',
	);
	my $dn      = $cgi->textfield(
		-'name' => 'dn', -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => '',
	);
			#<tr><td>dn: </td> 	<td>$dn</td></tr>     
	my $hdn     = $cgi->hidden(
		-'name' => 'dn', -'override' => 1,
		-'default' => 'invalid :-]',
	);
	print qq|
		<form action=ldap.cgi>
		<table border=0>
			<tr><td>cn: </td> 	<td>$cn</td></tr>     
			<tr><td>$submit</td> 	<td>$reset</td></tr>	
			$hdn
		</table>
		</form>
	|;
} else {
	$o_vac = $o_vac->start;
	my $o_ldap = $o_vac->_ldap;

	# cgi params 
	my $xfrom    = $cgi->param('outgoingSender'); 
	my $xsn		 = $cgi->param('sn'); 
	my $xstart   = $cgi->param('start'); 
	my $xend     = $cgi->param('end');
	my $xforward = $cgi->param('forward'); 
	my $xmessage = $cgi->param('message');
	my $xmodify  = $cgi->param('modify');

	my $startok  = '';
	my $endok    = '';

	my $hr = '<hr>';
	my $i_ok = 0;
	if ($xmodify) {	
		unless ($xdn =~ /\w+/o) {
			error("missing required dn($xdn) field");
		} else {
			my $startok = &ParseDate($xstart);
			unless ($startok =~ /\d+/o) {
				error("invalid start($xstart) date $startok");
			} else {
				my $endok = &ParseDate($xend);
				unless ($endok =~ /\d+/o) {
					error("invalid end($xend) date $endok");
				} else {
					unless (&Date_Cmp($startok, $endok) == -1) {
						error("start($xstart) must come before end($xend)");
					} else {
						unless ($xforward =~ /\@/o) {
							print "no forward($xforward) email address supplied<br>\n";
						} else {
							my ($o_addr) = Mail::Address->parse($xforward);
							my $forwardok = $o_addr->address;
							unless ($forwardok =~ /\w+/o) {
								error("invalid forwarding email address($xforward) format");
							}
						}	
						$i_ok = 1;
						unless ($xmessage =~ /\w+/o) {
							print "no vacation message($xmessage) given<br>\n";
						}
					}
				}
			}
		}
	}

	if ($i_ok == 1) {
		my $crlf = $o_vac->config->crlf;
		$xmessage =~ s/\n/\015\012/gmos if $crlf eq 'yes';
		my $modify = $o_ldap->modify($xdn,
			'replace'	=> {
				#'outgoingSender'	=> $xfrom,
				'sn'				=> $xsn,
				#'vacation start'	=> $startok,
				#'vacation end'		=> $endok,
				#'vacation forward'	=> $xforward,
				#'vacation message'	=> $xmessage,
			}
		);
		if ($modify->code) {
		  error("LDAP modify $$ failed: ".ldap_error_string($modify));
		} else {
		  $o_ldap->sync;
		  $hr .= $hr;
		}
	}
		
	# my %vac = $o_vac->config->hash('vacation');
	# my $alias = $vac{address} || ''; # can't use this - multiple entries
	my $xcn  = $cgi->param('cn')  || ''; # login
	my %req = (
		# filter  => "(cn=*)",
		# filter  => "(dn=$xdn)", # ...?
		filter  => "(cn=$xcn)",
	);
	my $mesg = $o_ldap->search(%req);
	if ($mesg->code) {
	  error("LDAP Search failed: ".ldap_error_string($mesg));
	}
	my $i_cnt = $mesg->count;
	unless ($i_cnt == 1) {
	  error("No ($i_cnt) Entry '$xdn' on LDAP server ".Dumper(\%req));
	}
	my @entries = $mesg->entries;
	my $entry = $entries[0];

	# attributes
	if (0) {
		print table({-border => 1},
			caption($xreq),
			Tr([ th([ 'Attribute', 'Values' ]),
					 map { td({-valign => 'top'}, [$_, get_value($entry, $_)]); } $entry->attributes
				   ])
		);
	}

	my $sort = 'cn';
	@entries = sort {$a->get_value($sort) cmp $b->get_value($sort)} @entries;

	# dn entry
	if (0) {
		print table({-border => 1},
			caption($mesg->count . $xreq),
			Tr([ th([ (map { a({-href => "$relative_url?request=dn"}, $_)}
						   @$attrs
						  ), 'dn' ]),
					 map { td({-valign => 'top'}, all_values($_)); } @entries
				])
		  );
	} 

	# form fields
	my $ecn     = $entry->get_value('cn');
	my $efrom   = $entry->get_value('outgoingSender');
	my $edn		= $entry->dn;
	my $hdn     = $cgi->hidden(
		-'name' => 'dn', -'override' => 1,
		-'default' => $edn,
	);
	my $hcn     = $cgi->hidden(
		-'name' => 'cn', -'override' => 1,
		-'default' => $ecn,
	);
	my $sn      = $cgi->textfield(
		-'name' => 'sn', -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => $entry->get_value('sn'),
	);
	my $start   = $cgi->textfield(
		-'name' => 'start', -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => $entry->get_value('vacation start'),
	);
	my $end     = $cgi->textfield(
		-'name' => 'end',   -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => $entry->get_value('vacation end'),
	);
	my $forward = $cgi->textfield(
		-'name' => 'forward',   -'size' => 35, -'maxlength' => 45, -'override' => 1,
		-'default' => $entry->get_value('vacation forward'),
	);
	my $message = $cgi->textarea(
		-'name' => 'message',   -'rows' => 5, -'columns' => 50, -'override'	=> 1,
		-'default' => $entry->get_value('vacation message'),
	);
	$message =~ s/\015?\012/\n/gmos; # crlf

	$submit  = $cgi->submit(
		-'name' => 'modify', -'value' => 'Modify',
	);

	# form
	print qq|
		<form action=ldap.cgi>
		<table border=0>
			<tr><td colspan=2>		$edn $hr</td></tr>     
			<tr><td>cn: </td> 	<td>$ecn</td></tr>     
			<tr><td>sn: </td> 	<td>$sn</td></tr>     
			<tr><td>From: </td> 	<td>$efrom</td></tr>     
			<tr><td>Start: </td> 	<td>$start</td></tr>	
			<tr><td>End: </td> 		<td>$end</td></tr>   	
			<tr><td>Forward: </td> 	<td>$forward</td></tr>	
			<tr><td colspan=2>Message: <br>                 
										$message</td></tr>	
			<tr><td>$submit</td> 	<td>$reset</td></tr>	
			$hdn $hcn
		</table>
		</form>
	|;
	$o_vac->finish;
}

exit(0);

# subs
# -----------------------------------------------------------------------------

sub all_values {
  my $entry = shift;
  my $escpd = uri_escape($entry->dn);
  return [ 
	(map { get_value($entry, $_);  } @$attrs),
         qq|<a href="ldap.cgi?request=dn&dn=$escpd">|.$entry->dn.'</a>'
  ];
}

sub get_value {
  my $entry = shift;
  my $attr = shift;

  my @values = $entry->get_value($_);
  # return @values ? join('<br>', @values) : '&nbsp;';
  return @values ? join('<br>', map { linkify($_); } @values) : '&nbsp;';
}

sub linkify {
  my $string = shift;
  if ($string =~ /^cn=.*o=/) {
	my $escpd = uri_escape($string);
	return qq|<a href="$relative_url?request=dn&dn=$escpd">$string</a>|;
  } else {
    # Return as it is.
    return $_;
  }
}

sub ldap_error_string {
  my $mesg = shift;
  if (length $mesg->error) {
    return $mesg->error;
  } elsif (ldap_error_text($mesg->code)) {
    return ldap_error_text($mesg->code);
  } else {
    return ldap_error_name($mesg->code);
  }
}

sub error {
	my $s_msg = shift;
	print "<h3>Error: $s_msg</h3>\n";
	exit(1);
}

__END__

# 
