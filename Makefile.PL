use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# remove contents of dbs (test generated)

WriteMakefile(
    'NAME'			=> 'Mail::Vacation',
    'VERSION_FROM'	=> 'Vacation.pm', # finds $VERSION
    'PREREQ_PM'		=> {
	'Carp'			=> '',
	'Config::General'=>'2.07',
	'Data::Dumper'	=> '',
	'Date::Manip'	=> '',
	'DB_File::Lock'	=> '0.05',
	'Fcntl'			=> '1.04',
	'Mail::Address' => '',
	'Mail::Internet'=> '',
	'Mail::Mailer'  => '',
	'Mail::Util' 	=> '',
	'Net::LDAP' 	=> '0.25',
	'Sys::Syslog' 	=> '',
	'Test::More' 	=> '',
	'Tie::File' 	=> '',
	}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'Vacation.pm', # retrieve abstract from module
       AUTHOR     => 'Richard Foley <richard.foley@rfi.net>'
	) : ()),
);
