# $Id: $

=head1 NAME

Mail::Vacation::LDAP - handler for specific methods 

=head1 DESCRIPTION

perl implementation of vacation program, authorisation and control via LDAP

=cut

package Mail::Vacation::LDAP;

=head1 SYNOPSIS

See L<Mail::Vacation>

=head1 ABSTRACT

Perl implementation of the vacation mail handling program, using LDAP as the authentication and control protocol.

=head1 NOTES

Configure this instance in the 'conf/ldap.conf' file

=head1 SCRIPTS

=over 4

=item ldap.pl

ldap script expecting running ldap server with appropriate entries - as per config file

=item ldap.cgi

browse ldap entries via web server

todo: modify entries

=cut

use 5.00;
use strict;
use warnings;
use vars qw(@ISA $VERSION $DEBUG);
$| = 1;

our $VERSION = '0.03';
our $DEBUG   = $Mail::Vacation::DEBUG || 0;
# $Mail::Vacation::DEBUG = $DEBUG;

=head1 SEE ALSO

See also L<Mail::Vacation>

=cut

use Carp qw(croak);
use Data::Dumper;
use Date::Manip;
use DB_File;
use Mail::Vacation;
use Net::LDAP;
use Tie::File;

@ISA = qw(Mail::Vacation);

=head2 EXPORT

None by default.

#=cut

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( );

=cut

#	Check for ldap server
#
#	$o_vac->_configure($configfile);

sub _configure {
	my $self   = shift;
	my $config = shift || '';

	$self = $self->SUPER::_configure($config);

	if ($self) {
		my $o_conf = $self->_config;
		unless ($o_conf->server =~ /^([a-z][\w.]+)$/io) {
			$self = $self->_error("no server given: ".Dumper($o_conf));
		}
	}	

	return $self;
}

#	Returns current ldap handler object
#
#	$o_ldap = $o_vac->_ldap;

sub _ldap {
	my $self = shift;
	
	my $o_ldap = $self->{_handler} || '';
	unless (ref($o_ldap)) {
		$self = $self->_error("invalid ldap object($o_ldap) - not started or perhaps disconnected?");
	}

	return $o_ldap;
}

#	Connect and bind to the ldap server from the configuration file
#
#	$o_vac->start;

sub start {
	my $self = shift;

	$self = $self->SUPER::start();

	if (ref($self)) { 
		$self->finish if $self->{_connected};
		my $server = $self->_config->server;
		my %options = $self->_config->hash('server_options');
		my $o_ldap = $self->{_handler} = Net::LDAP->new($server, %options) || "no ldap server?";
		unless (ref($o_ldap)) {
			$self = $self->_error("can't connect to $o_ldap with options: ".Dumper(\%options));
		} else {
			$self->_log("connected to running server($server)"); 
			my %bindings = $self->_config->hash('bind_options');
			my $o_msg = $o_ldap->bind(%bindings);
			if ($o_msg->code) {
				$self = $self->_error("failed to bind: ".$o_msg->error);
			} else {
				$self->{_connected}++;
				$self->_log("bound to server($server)"); 
			}
		}
	}

	return $self;	
}

#	Retrieve the users requested attribute=value pairs data in hashref/s
#
#	($userdata) = $o_vac->_retrieve('filter' => '(cn=common_name)');
#
#	@hash_refs  = $o_vac->_retrieve(%search_parameters);

sub _retrieve {
	my $self  = shift;
	my %pars  = @_;
	my @hret  = ();
	my $i_fnd = 0;

	unless (keys %pars >= 1 && defined($pars{filter}) && $pars{filter} =~ /.+/o) {
		$self->_error("missing required search parameters: ".Dumper(\%pars));
	} else {
		my $o_ldap = $self->_ldap;
		if ($o_ldap) {
			my $o_msg = $o_ldap->search(%pars);
			if ($o_msg->code) {
				$self->_error("LDAP search failure: ".$o_msg->error.' via: '.Dumper(\%pars));
			} else {
				unless ($o_msg->count) {
					$self->_error("no LDAP entries for %pars");
				} else {
					$i_fnd++;
					my $i_entries = my @entries = $o_msg->entries;				
					$self->_log("found $i_entries entry/ies");
					foreach my $o_entry (@entries) {
						my %attrs = ();
						foreach my $attr ($o_entry->attributes) {	
							my $val = $o_entry->get_value($attr) || '';
							$attrs{$attr} = $val;
						}
						push(@hret, \%attrs);
					}
				}
			}
		}
	}

	return @hret;
}

#	Returns message whether or not this mail addressee is on ldap vacation.
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
		$self = $self->_error("missing required user address($user) from mail");
	} else {
		my $testflag =  $self->_config->testflag;
		my %attrs    =  $self->_config->hash('attributes');
		my %options  = ($self->_config->hash('search_options'), 'attrs' => [values %attrs]);
		$options{'filter'} =~ s/($attrs{userkey})=\%s/$1=$user/;
		# filter	(&(canTakeAVacation=1)(uid=%s))
		my ($h_data) = ($testflag == 1 && ref($h_test) eq 'HASH') ? $h_test : $self->_retrieve(%options);
		unless (ref($h_data)) {
			$self = $self->_error("no data found for user($user)");
		} else {
			my $i_invac = $self->_invacation($h_data);
			if ($i_invac == 1) {
				my $fromaddr = $attrs{from}   || ''; # key
				$from = $$h_data{$fromaddr}   || '';
				my $message = $attrs{message} || ''; # key
				$msg = $$h_data{$message}     || $attrs{default_message} || '';
				$msg =~ s/\015?\012/\n/gmos; # crlf
				unless ($from =~ /\w+/o && $msg =~ /(.+)/mos) {
					$self->_log("$user has no from address($from) and/or $message data($msg)");
				} else {
					$self = $self->_log("found vacation from($from) and message chars(@{[length($msg)]})");
				}
				my @forward = (ref($attrs{forward}) eq 'ARRAY') ? @{$attrs{forward}} : $attrs{forward} || ''; # key
				my @fwd = ();
				foreach my $forward (@forward) {
					my $addr = $$h_data{$forward} || '';
					push(@fwd, $addr) if $addr;
				}
				unless (@fwd >= 1) {
					$self->_log("$user has no forwarding(@forward) data(@fwd)");
				} else {
					$self = $self->_log("found vacation forward(@forward) data(@fwd)");
				}
			}
		}
	}

	return ($from, $msg, \@fwd);
}

#	unbind from server
#
#	$o_vac->finish;

sub finish {
	my $self = shift;

	$self = $self->SUPER::finish();

	my $o_ldap = $self->_ldap; 
	if (ref($o_ldap)) {
		my $server = $self->_config->server;
		unless ($o_ldap->unbind) {
			$self = $self->_log("can't unbind from $o_ldap server($server)");	
		} else {
			$self->{_ldap} = undef;
			$self->{_connected}--;
			$self->_log("unbound from server($server)"); 
		}
	}

	return $self;	
}

#	close connection

sub DESTROY {
	my $self = shift;

	$self->finish($self->{_server});
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

