# $Id: $

=head1 NAME

Mail::Vacation - implements unix vacation program

=head1 DESCRIPTION

Reimplentation of the unix <B>vacation</B> program, with the intention
of using various authorisation and control configurations, eg LDAP.

=cut

package Mail::Vacation;

=head1 SYNOPSIS

  use Mail::Vacation;

  $o_vac  = Mail::Vacation->new($config) or die("failed :-(");

  $o_vac->start;

  $o_vac->process($o_mail_internet); 

  $o_vac->finish;

  $i_isok = $o_vac->isok;

  @s_msgs = $o_vac->messages;

=head1 ABSTRACT

Perl implementation of the vacation mail handling program, with the
intention of using various authorisation and control configurations,
eg LDAP.  Logging to syslog.

=head1 NOTES

Configure this instance in the 'vacation.conf' file

Logging is via syslog to /var/log/messages, (make sure syslogd is running!)

=head1 SCRIPTS

=over4

=item vacation.pl

standard vacation script expecting /home/$user/.vacation message file to operate

=item cleanup.pl

cleans configurable time-expired repliedtodbdir entries via cron job

=item test.cgi

vanilla 'hello world' script to test httpd installation against script directory

=cut

use 5.00;
use strict;
use warnings;
$| = 1;

our $VERSION = '0.05';
our $DEBUG   = $Mail::Vacation::DEBUG || 0;

=head1 SEE ALSO

Config::General::Extended

Mail::Internet

Sys::Syslog

=cut

use Carp qw(croak);
use Config::General;
use Data::Dumper;
use Date::Manip;
use DB_File::Lock;
use Fcntl qw(:flock O_RDWR O_CREAT O_RDONLY);
use Mail::Address;
use Mail::Internet;
use Mail::Util;
use Mail::Mailer;
use Sys::Syslog;

=head2 EXPORT

None by default.

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( );

=item new

Create new Mail::Vacation object

  $o_vac = Mail::Vacation->new($config_file);

=cut

sub new {
	my $proto  = shift;
	my $class  = ref($proto) ? ref($proto) : $proto;
	my $config = shift || '';

	my $self = bless({}, $class);

	return $self->_reset($config);
}

#	Reread config file and reset object variables to defaults
#
#	$o_vac = $o_vac->_reset;

sub _reset {
	my $self   = shift;
	my $config = shift || $self->{_configfile} || ' ';

	unless ($config =~ /\w/o) {
		$self = $self->_error("no configfile($config) ".Dumper($self));
	}

	%{$self} = ( 
		%{$self},
		'_configfile'	=> $config,
		'_config'		=> $$self{_config} || {}, # o_conf
		'_connected'	=> 0,
		'_errors'		=> 0,
		'_isok'			=> 1,
		'_handler'		=> {}, 
		'_messages'		=> [],
	);

	$self = $self->_configure($config);

	return $self;	
}

#	Return the config object, value/s if given key/s
#
#	$o_conf = $o_vac->_config;
#
#	$val    = $o_vac->_config('key');
#
#	@attrs   = $o_vac->_config('attributes');

sub _config {
	my $self = shift;
	my @keys = @_;
	my @vals = ();

	my $o_conf = $self->{_config} || '';
	unless (ref($o_conf)) {
		$self = $self->_error("no configuration object($o_conf)");
	} else {
		unless (@keys) {
			push(@vals, $o_conf);
		} else {
			foreach my $key (@keys) {	
				# push(@vals, $o_conf->{config}{$key}); # General
				push(@vals, $o_conf->$key()); 			# Extended
			}
		}
	}

	return wantarray ? @vals : $vals[0];
}

#	Read in the configuration file and set up the object
#
#	$o_vac->_configure($configfile);

sub _configure {
	my $self   = shift;
	my $config = shift || ' ';

	unless (openlog('vacation', 'cons,pid', 'user')) {
		$self = $self->_error("can't open syslog for vacation $!"); # syslog
	} else {
		# my $o_conf = $self->{_config} = Config::General::Extended->new($config); # deprecated
		my $o_conf = $self->{_config} = Config::General->new(-ConfigFile=>$config,-ExtendedAccess=>1);
		unless (ref($o_conf)) {
			$self = $self->_error("no configuration($config) object($o_conf)");
		} else {
			$self->_log("configuration($config) object($o_conf) ok");
		}
	}	

	return $self;
}

=item start

Things to do before we process anything

	$o_vac->start();

=cut

sub start {
	my $self  = shift;
	 
	# nothing to do

	return $self;
}

=item finish

Finishing stuff goes here

	$o_vac->finish();

=cut

sub finish {
	my $self  = shift;

	# nothing to do

	return $self;
}

=item process

Process the given mail 

	$o_vac->process($o_main_internet, [h_test]);

=cut

sub process {
	my $self  = shift;
	my $o_int = shift || '';
	my $h_test= shift || ''; # unsupported

	unless (ref($o_int) eq 'Mail::Internet') {
		$self = $self->_error("invalid process mail object($o_int)");
	} else {
		if ($self->_looks_ok($o_int)) {
			my ($from, $s_msg, $a_fwd) = $self->_onvacation($h_test);
			if ($s_msg) {
				$self = $self->_reply($o_int, $s_msg);
				$self = $self->_forward($o_int, $a_fwd) if $self;
			} 
		}
	}

	return $self;
}

#	Checks incoming mail is valid.
#
#	$o_vac->_looks_ok($o_int);

sub _looks_ok {
	my $self  = shift;
	my $o_int = shift || '';

	unless (ref($o_int) eq 'Mail::Internet') {
		$self = $self->_error("invalid looks_ok mail object($o_int)");
	} else {
		my $o_hdr = $o_int->head; 
		my $xloop = $o_hdr->get('X-Mail-Vacation') || '';
		if ($xloop =~ /\w/o) {
			$self = $self->_error("mail seen before($xloop)") if $xloop =~ /\w/o;
		} else {
			my $xlist = $o_hdr->get('X-Mailing-List') || '';
			if ($xlist =~ /\w/o) {
				$self = $self->_error("mailing list($xlist)") if $xlist =~ /\w/o;
			}
		}
	}

	return $self;
}

#	Returns user name in B<To> field
#
#	$user = $o_vac->_int2user($o_int);

sub _int2user {
	my $self  = shift;
	my $o_int = shift;
	my $user  = '';
		
	unless (ref($o_int) eq 'Mail::Internet') {
		$self = $self->_error("invalid int2user mail object($o_int)");
	} else {
		my $addr = $o_int->head->get('To');
		my ($o_addr) = Mail::Address->parse($addr);
		$user = $o_addr->user if ref($o_addr);
		unless ($user =~ /\w+/o) {
			$self = $self->_error("missing required user($user) from address($addr)");
		}
	}

	return $user;
}

#	Returns true or false, whether given date is within vacation period
#
#	$i_trueorfalse = $o_vac->_invacation(\%dates); # start=>$x,now=>$y,end=>$z

sub _invacation {
	my $self    = shift;
	my $h_dates = shift || '';
	my $i_in    = 0;

	unless (ref($h_dates) eq 'HASH') {
		$self->_error("invalid date hash ref($h_dates)");
	} else {
		my %attr     = $self->_config->hash('attributes');
		my $startkey = $attr{start} || 'start';
		my $endkey   = $attr{end}   || 'end';
		my %date  = map { lc($_) => $h_dates->{$_} } keys %{$h_dates};
		my $start = ParseDate($date{$startkey} || '');
		my $date  = ParseDate($date{now}       || 'now');
		my $end   = ParseDate($date{$endkey}   || '99991120'); # year 10000 problem ?-)
		unless ($start =~ /\d+/o) {
			$self->_error("invalid start date($start)");
		} else {
			unless ($date =~ /\d+/o) {
				$self->_error("invalid current date($date)");
			} else {
				unless ($end =~ /\d+/o) {
					$self->_error("invalid end date($end)");
				} else {
					$i_in = ((&Date_Cmp($start, $date) < 0) && (&Date_Cmp($date, $end) < 0)) ? 1 : 0;
					$self->_log("start($start) date($date) end($end) => i_int($i_in)");
				}
			}
		}
	}

	return $i_in;
}

#   Returns from address and message if this mail addressee is on vacation.
#   Also returns array ref of forwarding email addresses, if applicable.
#
#	($from, $message, \@fwd) = $o_vac->_onvacation([h_test]);

sub _onvacation {
	my $self  = shift;
	my $h_test= shift || ''; # unsupported
	my $msg   = '';
	my @fwd   = ();
		
	my $from = $self->_mailfrom();#$o_int);

	my %env  = $self->_config->hash('env');
	my $user = $ENV{$env{user}} || '';
	unless ($user =~ /\w+/o) {
		$self = $self->_error("missing required env user($user)");
	} else {
		my $vac = $self->_config('homedir')."/$user/.vacation";
		# my $fwd = $self->_config('homedir')."/$user/.forward";
		my $o_vac = tie my @vac, 'Tie::File', $vac, 'mode' => O_RDONLY;
		unless (ref($o_vac)) {
			$self = $self->_error("problem reading $vac $!");
		} else {
			$msg = join("\n", @vac);
			$msg =~ s/\015?\012/\n/gmos; # crlf
			$self = $self->_log("found vacation message chars(@{[length($msg)]})");
			# untie @vac; # scope
		}
	}

	return ($from, $msg, \@fwd);
}

#	Return from address for use in reply ($USER)
#
#	$from = $o_vac->_mailfrom($o_int);

sub _mailfrom {
	my $self  = shift;
	my $o_int = shift; # ignored

	my %env = $self->_config->hash('env');

	my $from = qq|"$ENV{$env{extension}}" <$ENV{$env{local}}\@$ENV{$env{domain}}>|;
	
	return $from;	
}

#	track and reply to sender with given message
#
#	$o_vac->_reply($o_int, $message);

sub _reply {
	my $self  = shift;
	my $o_int = shift || '';
	my $s_msg = shift || '';
		
	unless (ref($o_int) eq 'Mail::Internet' && $s_msg =~ /\w+/mos) { 
		$self = $self->_error("invalid reply mail object($o_int) or message($s_msg)");
	} else {
		my $o_hdr  = $o_int->head;
		my ($from) = $o_hdr->get('Reply-To') || $o_hdr->get('From') || '';
		my @tocc   =($o_hdr->get('To'), $o_hdr->get('Cc')); 
		my ($to, @cc) = $self->_track($from, \@tocc); # 
		my $cc = join(', ', @cc) || '';

		unless ($to && $to =~ /\w+\@\w+/o) {
			$to = '' unless $to;
			@cc = () unless @cc; 
			$self = $self->_error("missing to($to) => nothing to do");	
		} else {
			my $o_reply = $o_int->reply;
			$o_reply->head->cleanup();
			$o_reply->head->replace('From', $self->_mailfrom($o_int));
			$o_reply->head->replace('X-Mail-Vacation', ref($self)." v$Mail::Vacation::VERSION $$");
			$o_reply->remove_sig();
			if ($s_msg) {
				my $sendmail = $self->_config('sendmail');
				my $o_send = Mail::Mailer->new($sendmail);
				unless ($o_send) {
					$self = $self->_error("cannot open reply mailer($sendmail)");
				} else {
					my $h_hdrs = $o_reply->head->header_hashref;
					unless ($o_send->open($h_hdrs)) {
						$self = $self->_error("cannot open for reply header: ".Dumper($o_reply->head));
					} else {
						unless (print $o_send $s_msg) {
							$self = $self->_error("cannot print reply body($s_msg)");
						} else {
							unless ($o_send->close) { 
								$self = $self->_error("cannot close reply $o_send mail");
							} else {
								$self->_log("replied to($to) cc($cc) was from($from) via $o_send");
							}
						}
					}
				}
			}
		}
	}

	return $self;
}

#	track and forward to given forwarding addresses
#
#	$o_vac->_forward($o_int, $a_fwd);

sub _forward {
	my $self  = shift;
	my $o_int = shift || '';
	my $a_fwd = shift || '';
		
	unless (ref($o_int) eq 'Mail::Internet' && ref($a_fwd) eq 'ARRAY') {
		$self = $self->_error("invalid reply mail object($o_int) or forwarding addrs($a_fwd)");
	} else {
		my $o_hdr  = $o_int->head;
		my ($to, @cc) = my @addrs = @{$a_fwd};
		unless (defined($to) && $to =~ /\w+/o) {	
			$self->_log("no forwarding addresses(@addrs) - nothing to do");
		} else {
			my $o_head = $o_int->head;
			$o_head->cleanup();
			$o_head->replace('To', $to);
			$o_head->replace('Cc', join(',', @cc));
			$o_head->replace('X-Mail-Vacation', ref($self)." v$Mail::Vacation::VERSION $$");
			my $s_msg = join("\n", @{$o_int->body});
			if ($s_msg) {
				my $sendmail = $self->_config('sendmail');
				my $o_send = Mail::Mailer->new($sendmail);
				unless ($o_send) {
					$self = $self->_error("cannot open new forwarder($sendmail)");
				} else {
					my $h_hdrs = $o_head->header_hashref;
					unless ($o_send->open($h_hdrs)) {
						$self = $self->_error("cannot open forward header: ".Dumper($o_head));
					} else {
						unless (print $o_send $s_msg) {
							$self = $self->_error("cannot print forward body($s_msg)");
						} else {
							unless ($o_send->close) { 
								$self = $self->_error("cannot close forward $o_send mail");
							} else {
								my $from = $o_head->get('From');
								$self->_log("forwarded to($to) cc(@cc) was from($from) via $o_send");
							}
						}
					}
				}
			}
		}
	}

	return $self;
}

#	Retrieve the users requested attribute=value pairs data in hashref/s
#
#	($userdata) = $o_vac->_retrieve('filter'	=> '(uname=richardf)');
#
#	@hash_refs  = $o_vac->_retrieve(%search_parameters);

sub _retrieve {
	my $self = shift;
	my %pars = @_;
	my @hret = ();

	unless (keys %pars >= 1 && defined($pars{filter}) && $pars{filter} =~ /.+/o) {
		$self->_error("missing required search parameters: ".Dumper(\%pars));
	} else {
		my %data = ();
		$data{'message'} = 'unimplemented';
		push(@hret, \%data);
	}

	return @hret;
}

#	Track this/these address/es in the replied-to db.
#
#	Returns appropriate addresses to reply to.
#
#	($to, @cc) = $o_vac->_track($from, \@addresses);

sub _track {
	my $self   = shift;
	my $xfrom  = shift;
	my $a_tocc = shift || [];
	my %addr   = ();

	my $dir = $self->_config('repliedtodbdir') || ''; 
	unless (-d $dir && -x _) {
		$self = $self->_error("invalid replied to db dir($dir) $!");	
	} else {
		my ($o_from) = Mail::Address->parse($xfrom);
		my $from = ref($o_from) ? $o_from->address : '';
		unless ($from =~ /\w+\@\w+/io) {
			$self = $self->_error("missing required from($xfrom) address($from)");
		} else {
			my $file = "$dir/$from";
        	unless (tie my %hash,  'DB_File::Lock', $file, O_CREAT|O_RDWR, 0666, $DB_HASH, 'write') {
				$self = $self->_error("failed to _track repliedto db($file) $!");
			} else {
				unless (ref($a_tocc) eq 'ARRAY') {
					$self->_log("missing to or ccs addrs: ".Dumper($a_tocc));
				} else {
					my $now = &ParseDate('now');
					my $min = &DateCalc( 'now', '- '.($self->_config('expirytime')||14).' days'); # 12 (days)
					foreach my $xaddr (@{$a_tocc}) {	
						my ($o_addr) = Mail::Address->parse($xaddr);
						my $addr = ref($o_addr) ? lc($o_addr->address) : '';
						if ($addr =~ /\w+\@\w+/o) { 		# get put del
							$addr =~ tr/[A-Z]/[a-z]/;
							my $date = $hash{$addr} || 0; # get
							$addr{$addr}++ unless &Date_Cmp($date, $min) > 0;
							$hash{$addr} = $date || $now;             # store
						}
					}
				}
				untie(%hash); # really 
				unlink "$file.lock" if -e "$file.lock"; # still ?!
			}
		}
	}

	return keys %addr;
}

=item cleanup 

Cleanup replied-to dbs based on (now - expirytime) or optionally given
date.  All entries older than given date will be removed, to clean a file,
you can empty it by giving a date of, for example, '99999999'.

	$o_vac->cleanup($date, [opt_a_ref_addresses]);

=cut

sub cleanup {
	my $self   = shift;
	my $date   = shift || '';
	my $a_addrs= shift || '';

	my $dir = $self->_config('repliedtodbdir') || ''; 
	unless (-d $dir && -x _) {
		$self = $self->_error("invalid replied to db dir($dir) $!");	
	} else {
		$date = $date ? &ParseDate($date) : &DateCalc('now', '- '.$self->_config('expirytime').' days'); # 12 (days)
		unless (opendir(DIR, $dir)) {
			$self = $self->_error("can't open repliedtodbdir $dir: $!");
		} else {
			my $addrs = (ref($a_addrs) eq 'ARRAY') ? join('|', map { quotemeta($_) } @{$a_addrs}) : '\w';
			my @addrs = grep { /$addrs/o && /\@/o && !/\.lock$/ && -f "$dir/$_" } readdir(DIR);
	        closedir DIR;
			my $i_del = 0;
			my @trim  = ();
			ADDR:
			foreach my $addr (@addrs) {
				my %hash = ();	
				my $file = "$dir/$addr";
				unless (tie %hash,  'DB_File::Lock', $file, O_CREAT|O_RDWR, 0666, $DB_HASH, 'write') {
					$self->_error("failed to _cleanup repliedto db($file) $!");
				} else {
					foreach my $targ (keys %hash) {
						my $stored = $hash{$targ} || 0; 	# get
						if (&Date_Cmp($stored, $date) < 0) {
							delete $hash{$targ};
							$i_del++;
						}
					}
					push(@trim, $addr) unless keys %hash >= 1;
				}
				untie(%hash); # really 
				unlink "$file.lock" if -e "$file.lock"; # still ?!
			}
			$self->_log("deleted $i_del entries from ".@addrs." files");
			if (@trim >= 1) {
				my $i_rem = unlink map { "$dir/$_" } @trim;
				unless ($i_rem == @trim) {
					$self = $self->_error("Failed to remove($i_rem) ".@trim." empty $dir entries");
				}
			}
		}
	}

	return $self;
}

#	Send message to syslog if $Mail::Vacation::DEBUG is set
#
#	$o_vac->_log($msg);

sub _log {
	my $self = shift;

	$self = $self->_xlog(@_) if $Mail::Vacation::DEBUG;

	return $self;
}

sub _xlog {
	my $self = shift;

	unless (syslog('info', join(' ', @_))) {
		print STDERR "nosyslog($$): ".join(' ', @_, "\n");
	}

	return $self;
}

#	Send error message to syslog.
#
#	$o_vac->_error($msg); # <- returns undef

sub _error {
	my $self = shift;

	$self->_log('error: ', @_);

	$self->{_isok} = 0;
	$self->{_error}++;
	push(@{$self->{_messages}}, @_);

	return undef;	
}

=item isok

Return current valid value

	$i_isok = $o_vac->isok;

=cut

sub isok {
	my $self = shift;

	return $self->{_isok};
}

=item messages

Return current messages

	print $o_vac->messages;

=cut

sub messages {
	my $self = shift;

	return @{$self->{_messages}};
}

#	Send error message to syslog and die.
#
#	$o_vac->_fatal($msg); # <- die's

sub _fatal {
	my $self = shift;

	$self->_xlog('error: ', @_);

	croak(@_);
}

#	Dumps the object
#
#	$o_vac->_dump;

sub _dump {
	my $self = shift;

	return Dumper($self);
}

#	Return Mail::Internet object from dir/file:
#	
#	my $o_int = $o_vac->_file2minet($filename);

sub _file2minet {
	my $self  = shift;
	my $file  = shift;
	my $o_int = '';

	unless ($file) {
		$self->_error("no mail file($file)");
	} else {
		my $FH = FileHandle->new("< $file");
		unless (defined($FH)) {
			undef $o_int;
			$self->_error("FileHandle($FH) not defined for file ($file): $!");
		} else {	
			$o_int = Mail::Internet->new($FH);
			close $FH;
			unless (ref($o_int)) {
				$self->_error("Mail($o_int) not retrieved from file($file)");		
			}
		}
	} 

	return $o_int; 
}

#	Setup Mail::Internet object from given args, body is default unless given.
#
#	my $o_int = $o_vac->_setup_int(\%header, [$body]); # 'to' => 'to@x.net'
#	
#	my $o_int = $o_vac->_setup_int( $header, [$body]); # or could be folded

sub _setup_int {
	my $self   = shift;
	my $header = shift || '';
	my $body   = shift || 'no-body-given';
	my $o_int  = undef;
	
	my %header   = ();
	if (ref($header) eq 'HASH') {
		%header = %{$header};
	} else {
		if ($header =~ /^([^:]+:\s*\w+.*)/mo) { 
			$header =~ s/\r?\n\s+/ /gos; # unfold
			%header = ($header =~ /^([^:]+):(.*)$/gmo);	
		} else { 
			$self->_error("Can't setup int from invalid header($header)!");
		}
	}

	if (keys %header) {
		my $o_hdr = Mail::Header->new;
		TAG:
		foreach my $tag (keys %header) {
			my @tags = (ref($header{$tag})) eq 'ARRAY' ? @{$header{$tag}} : ($header{$tag});
			$tag =~ tr/\n/ /d; # strays
			$tag =~ s/^\s+//o; # 
			$tag =~ s/\s+$//o; # 
			if ($tag =~ /^\w+(\-\w+)*/) {
				$o_hdr->add($tag, @tags);
			} else {
				$self->_error("*** problem with tag($tag)");
			}
		}
		$o_hdr->add('Message-Id', $self->_get_rand_msgid) unless $o_hdr->get('Message-Id'); 
		$o_hdr->add('Subject', q|some irrelevant subject|) unless $o_hdr->get('Subject'); 

		$o_int = Mail::Internet->new(
			'Header' => $o_hdr, 
			'Body' => [map { "$_\n" } split("\n", $body)]
		);
		my $to   = $o_int->head->get('To') || '';
		my $from = $o_int->head->get('From') || ''; 
		if (!($to =~ /\w+/o && $from =~ /\w+/o)) { 
			$self->_error("Invalid mail($o_int) => to($to) from($from)");
			undef $o_int;
		}
	}

	return $o_int;
}

#	Returns randomised recognisableid . processid . rand(time)
#
#	my $it = $o_vac->_get_rand_msgid(); # <19870502_$$.$time.$count@rfi.net>

sub _get_rand_msgid {
	my $self = shift;
 
	my $domain = Mail::Util::maildomain();
    if ($^O eq 'MSWin32') {
	   $domain = $ENV{'USERDOMAIN'};
    } else {
	  require Sys::Hostname;
	  $domain = Sys::Hostname::hostname();
    }

	my $msgid = '<'.(join('_', 
		ref($self), $$, time.'@'.$domain
	)).'>';

	return $msgid;
}

#	clean up, close syslog.

sub DESTROY {
	my $self = shift;

	closelog(); # syslog
}

=head1 AUTHOR

Richard Foley, E<lt>richard.foley@rfi.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2002 by Richard Foley

Sponsered by Octogon Gmbh, Feldafing, Germany

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

1;

