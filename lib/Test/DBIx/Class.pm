package Test::DBIx::Class;

use 5.008;
use strict;
use warnings;

use base 'Test::Builder::Module';

our $VERSION = '0.01';
our $AUTHORITY = 'cpan:JJNAPIORK';

use Test::DBIx::Class::SchemaManager;
use Path::Class;
use Config::Any;
use Hash::Merge;
use Sub::Exporter;
use Test::More ();
use Digest::MD5;
use Scalar::Util 'blessed';

sub import {
	my ($class, @opts) = @_;
	my ($schema_manager, $merged_config, @exports) = $class->_initialize(@opts);

	my $exporter = Sub::Exporter::build_exporter({
		exports => [
			dump_settings => sub {
				return sub {
					return $merged_config, @exports;
				};
			},
			Schema => sub {
				return sub {
					return $schema_manager->schema;
				}
			},
			ResultSet => sub {
				my ($local_class, $name, $arg) = @_;
				return sub {
					my $source = shift @_;
					my $search = shift @_;
					my $resultset = $schema_manager->schema->resultset($source);

					if(my $global_search = $arg->{search}) {
						my @global_search = ref $global_search eq 'ARRAY' ? @$global_search : ($global_search);
						$resultset = $resultset->search(@global_search);
					}

					if(my $global_cb = $arg->{exec}) {
						$resultset = $global_cb->($resultset);
					}

					if($search) {
						my @search = ref $search ? @$search : ($search, @_);
						$resultset = $resultset->search(@search);
					}

					return $resultset;
				}
			},
			is_result => sub {
				return sub {
					my $rs = shift @_;
					my $compare = shift @_ || "DBIx::Class";
					my $message = shift @_;
					Test::More::isa_ok($rs, $compare, $message);
				}
			},
			is_resultset => sub {
				return sub {
					my $rs = shift @_;
					my $compare = shift @_ || "DBIx::Class::ResultSet";
					my $message = shift @_;
					Test::More::isa_ok($rs, $compare, $message);
				}
			},
			eq_result => sub {
				return sub {
					my ($result1, $result2, $message) = @_;
					$message = defined $message ? $message : ref($result1) . " equals " . ref($result2);
					if( ref($result1) eq ref($result2) ) {
						Test::More::is_deeply(
							{$result1->get_columns},
							{$result2->get_columns},
							$message,
						);
					} else {
						Test::More::fail($message ." :Result arguments not of same class");
					}
				},
			},
			eq_resultset => sub {
				return sub {
					my ($rs1, $rs2, $message) = @_;
					$message = defined $message ? $message : ref($rs1) . " equals " . ref($rs2);
					if( ref($rs1) eq ref($rs2) ) {
						($rs1, $rs2) = map {
							my @pks = $_->result_source->primary_columns;
							my @result = $_->search({}, {
								result_class => 'DBIx::Class::ResultClass::HashRefInflator',
								order_by => [@pks],
							})->all;
							[@result];
						} ($rs1, $rs2);

						Test::More::is_deeply([$rs1],[$rs2],$message);
					} else {
						Test::More::fail($message ." :ResultSet arguments not of same class");
					}
				},
			},
			hri_dump => sub {
				return sub {
					(shift)->search ({}, {
						result_class => 'DBIx::Class::ResultClass::HashRefInflator'
					});
				}
			},
			fixtures_ok => sub {
				return sub {
					my ($arg, $message) = @_;
					$message = defined $message ? $message : 'Fixtures Installed';

					if ($arg && ref $arg && (ref $arg eq 'CODE')) {
						eval {
							$arg->($schema_manager->schema);
						}; if($@) {
							Test::More::fail($message);
							$schema_manager->builder->diag($@);

						} else {
							Test::More::pass($message);
						}
					} elsif( $arg && ref $arg && (ref $arg eq 'HASH') ) {
						my @return;
						eval {
							@return = $schema_manager->install_fixtures($arg);
						}; if($@) {
							Test::More::fail($message);
							$schema_manager->builder->diag($@);
						} else {
							Test::More::pass($message);
							return @return;
						}
					} elsif( $arg ) {
						my @sets = ref $arg ? @$arg : ($arg);
						my @fixtures = $schema_manager->get_fixture_sets(@sets);
						my @return;
						foreach my $fixture (@fixtures) {
							eval {
								push @return, $schema_manager->install_fixtures($fixture);
							}; if($@) {
								Test::More::fail($message);
								$schema_manager->builder->diag($@);
							} else {
								Test::More::pass($message);
								return @return;
							}
						}
					} else {
						Test::More::fail("Can't figure out what fixtures you want");
					}
				}
			},
			is_fields => sub {
				my ($local_class, $name, $arg) = @_;
				my @default_fields = ();
				if(defined $arg && ref $arg eq 'HASH' && defined $arg->{fields}) {
					@default_fields = ref $arg->{fields} ? @{$arg->{fields}} : ($arg->{fields});
				}
				return sub {
					my @args = @_;
					my @fields = @default_fields;
					if(!ref($args[0]) || (ref($args[0]) eq 'ARRAY')) {
						my $fields = shift(@args);
						@fields = ref $fields ? @$fields : ($fields); 
					} 
					if(blessed $args[0] && 
						$args[0]->isa('DBIx::Class') && 
						!$args[0]->isa('DBIx::Class::ResultSet')
					) {
						my $result = shift(@args);
						unless(@fields) {
							my @pks = $result->result_source->primary_columns;
							push @fields, grep {
								my $field = $_; 
								$field ne ((grep { $field eq $_ } @pks)[0] || '')
							} ($result->result_source->columns);
						}
						my $compare = shift(@args);
						if(ref $compare eq 'HASH') {
						} elsif(ref $compare eq 'ARRAY') {
							my @localfields = @fields;
							$compare = {map {
								my $value = $_;
								my $key = shift(@localfields);
								$key => $value } @$compare};
							Test::More::fail('Too many fields!') if @localfields;
						} elsif(!ref $compare) {
							my @localfields = @fields;
							$compare = {map {
								my $value = $_;
								my $key = shift(@localfields);
								$key => $value } ($compare)};
							Test::More::fail('Too many fields!') if @localfields;
						}
						my $message = shift(@args) || 'Fields match';
						my $compare_rs = {map {
							die "$_ is not an available field"
							  unless $result->can($_); 
							$_ => $result->$_ } @fields};
						Test::More::is_deeply($compare_rs,$compare,$message);
						return $compare;
					} elsif (blessed $args[0] && $args[0]->isa('DBIx::Class::ResultSet')) {

						my $resultset = shift(@args);
						unless(@fields) {
							my @pks = $resultset->result_source->primary_columns;
							push @fields, grep {
								my $field = $_; 
								$field ne ((grep { $field eq $_ } @pks)[0] || '')
							} ($resultset->result_source->columns);
						}
						my @compare = @{shift(@args)};
						foreach (@compare) {
							if(!ref $_) {
								my @localfields = @fields;
								$_ = {map {
									my $value = $_;
									my $key = shift(@localfields);
									$key => $value } ($_)};
								Test::More::fail('Too many fields!') if @localfields;
							} elsif(ref $_ eq 'ARRAY') {
								my @localfields = @fields;
								$_ = {map {
									my $value = $_;
									my $key = shift(@localfields);
									$key => $value } (@$_)};
								Test::More::fail('Too many fields!') if @localfields;
							}
						}
						my $message = shift(@args) || 'Fields match';

						my @resultset = $resultset->search({}, {
								result_class => 'DBIx::Class::ResultClass::HashRefInflator',
								columns => [@fields],
							})->all;
						my %compare_rs;
						foreach my $row(@resultset) {
							my $id = Digest::MD5::md5_hex(join('.', map {$row->{$_}} sort keys %$row));
							$compare_rs{$id} = $row;
						}
						my %compare;
						foreach my $row(@compare) {
							my $id = Digest::MD5::md5_hex(join('.', map {$row->{$_}} sort keys %$row));
							$compare{$id} = $row;
						}
						Test::More::is_deeply(\%compare_rs,\%compare,$message);
						return \@compare;
					} else {
						die "I'm not sure what to do with your arguments";
					}
				};
			},
			reset_schema => sub {
				return sub {
					my $message = shift @_ || 'Schema reset complete';
					$schema_manager->reset;
					Test::More::pass($message);
				}
			},
			map {
				my $source = $_;
 				$source => sub {
					my ($local_class, $name, $arg) = @_;
					my $resultset = $schema_manager->schema->resultset($source);
					if(my $search = $arg->{search}) {
						my @search = ref $search eq 'ARRAY' ? @$search : ($search);
						$resultset = $resultset->search(@search);
					}
					return sub {
						my $search = shift @_;
						if($search) {
							my @search = ();
							if(ref $search && ref $search eq 'HASH') {
								@search = ($search, @_); 
							} else {
								@search = ({$search, @_});
							}
							return $resultset->search(@search);
						}
						return $resultset;
					}
				};
			} $schema_manager->schema->sources,
		],
		groups => {
			resultsets => [$schema_manager->schema->sources],
		},
		into_level => 1,	
	});



	$class->$exporter(
		qw/Schema ResultSet is_result is_resultset hri_dump fixtures_ok reset_schema
			eq_result eq_resultset is_fields dump_settings/,
		 @exports
	);
		
}

sub _initialize {
	my ($class, @opts) = @_;
	my ($config, @exports) = $class->_normalize_opts(@opts);
	my $merged_config = $class->_prepare_config($config);

	if(my $resultsets = delete $merged_config->{resultsets}) {
		if(ref $resultsets eq 'ARRAY') {
			push @exports, @$resultsets;
		} else {
			die '"resultsets" options must be a Array Reference.';
		}
	}
	my $merged_with_fixtures_config = $class->_prepare_fixtures($merged_config);
	my $schema_manager = $class->_initialize_schema($merged_with_fixtures_config);

	return (
		$schema_manager,
		$merged_config,
		@exports,
	);
}

sub _normalize_opts {
	my ($class, @opts) = @_;
	my ($config, @exports) = ({},());

	if(ref $opts[0]) {
		if(ref $opts[0] eq 'HASH') {
			$config = shift(@opts);
		} else {
			die 'First argument to "use Test::DBIx::Class @args" not properly formed.';
		}
	}

	while( my $opt = shift(@opts)) {
		if($opt =~m/^-(.+)/) {
			if($config->{$1}) {
				die "$1 already is defined as $config->{$1}";
			} else {
				$config->{$1} = shift(@opts);
			}
		} else {
			@exports = ($opt, @opts);
			last;
		}
	}

	if(my $resultsets = delete $config->{resultsets}) {
		if(ref $resultsets eq 'ARRAY') {
			push @exports, @$resultsets;
		} else {
			die '"resultsets" options must be a Array Reference.';
		}
	}

	@exports = map { ref $_ && ref $_ eq 'ARRAY' ? @$_:$_ } @exports;

	return ($config, @exports);
}

sub _prepare_fixtures {
	my ($class, $config) = @_;

	my @dirs;
	if(my $fixture_path = delete $config->{fixture_path}) {
		@dirs = $class->_normalize_config_path(
			$class->_default_fixture_paths, $fixture_path, 
		);
	} else {
		@dirs = $class->_normalize_config_path($class->_default_fixture_paths);
	}

		my @extensions = $class->_allowed_extensions;
		my @files = grep { $class->_is_allowed_extension($_) }
			map {Path::Class::dir($_)->children} 
			grep { -e $_  } @dirs;

		my $fixture_definitions = Config::Any->load_files({
			files => \@files,
			use_ext => 1,
		});

		my %merged_fixtures;
		foreach my $fixture_definition(@$fixture_definitions) {
			my ($path, $fixture) = each %$fixture_definition;
			my $file = Path::Class::file($path)->basename;
			$file =~s/\..{1,4}$//;
			if($merged_fixtures{$file}) {
				$merged_fixtures{$file} = Hash::Merge::merge($fixture, $merged_fixtures{$file});
			} else {
				$merged_fixtures{$file} = $fixture;
			}
		}

		if(my $old_fixture_sets = delete $config->{fixture_sets}) {
			my $new_fixture_sets = Hash::Merge::merge($old_fixture_sets, \%merged_fixtures );
			$config->{fixture_sets} = $new_fixture_sets;
		} else {
			$config->{fixture_sets} = \%merged_fixtures;
		}

	return $config;
}

sub _is_allowed_extension {
	my ($class, $file) = @_;
	my @extensions = $class->_allowed_extensions;
	foreach my $extension(@extensions) {
		if($file =~ m/\.$extension$/) {
			return $file;
		}
	}
	return;
}

sub _prepare_config {
	my ($class, $config) = @_;

	if(my $extra_config = delete $config->{config_path}) {
		my @config_data = $class->_load_via_config_any($extra_config);
		foreach my $config_datum(reverse @config_data) {
			$config = Hash::Merge::merge($config, $config_datum);
		}
	} else {
		my @config_data = $class->_load_via_config_any();
		foreach my $config_datum(reverse @config_data) {
			$config = Hash::Merge::merge($config, $config_datum);
		}
	}

	if(my $post_config = delete $config->{config_path}) {
		my @post_config_paths = $class->_normalize_external_paths($post_config); 
		my @extensions = $class->_allowed_extensions;
		my @post_config_files =  grep { -e $_} map {
			my $path = $_; 
			map {"$path.$_"} @extensions;
		} map {
			my @local_path = ref $_ ? @$_ : ($_);
			Path::Class::file(@local_path);
		} @post_config_paths;

	    $post_config = Config::Any->load_files({
			files => \@post_config_files,
			use_ext => 1,
		});
		foreach my $config_datum(reverse map { values %$_ } @$post_config) {
			$config = Hash::Merge::merge($config, $config_datum);
		}
	}

	return $config;
}

sub _load_via_config_any {
	my ($class, $extra_paths) = @_;
	my @files = $class->_valid_config_files($class->_default_paths, $extra_paths);

    my $config = Config::Any->load_files({
		files => \@files,
		use_ext => 1,
	});

	my @config_data = map { values %$_ } @$config;
	return @config_data;
}

sub _valid_config_files {
	my ($class, $default_paths, $extra_paths) = @_;
	my @extensions = $class->_allowed_extensions;
	my @paths = $class->_normalize_config_path($default_paths, $extra_paths);
	my @config_files = grep { -e $_} map { 
		my $path = $_; 
		map {"$path.$_"} @extensions;
	 } @paths;

	return @config_files;
}

sub _allowed_extensions {
	return @{ Config::Any->extensions };
}

sub _normalize_external_paths {
	my ($class, $extra_paths) = @_;
	my @extra_paths;
	if(!ref $extra_paths) {
		@extra_paths = ([$extra_paths]); ## "t/etc" => (["t/etc"])
	} elsif(ref $extra_paths eq 'ARRAY') {
		if(!ref $extra_paths->[0]) {
			@extra_paths = ($extra_paths); ## [qw( t etc )]
		} elsif( ref $extra_paths->[0] eq 'ARRAY') {
			@extra_paths = @$extra_paths;
		}
	}
	return @extra_paths;
}

sub _normalize_config_path {
	my ($class, $default_paths, $extra_paths) = @_;

	if(defined $extra_paths) {
		my @extra_paths = map { "$_" eq "+" ? @$default_paths : $_ } map {
			my @local_path = ref $_ ? @$_ : ($_);
			Path::Class::file(@local_path);
		} $class->_normalize_external_paths($extra_paths);

		return @extra_paths;	
	} else {
		return @$default_paths;
	}
}

sub _script_path {
	return ($0 =~m/^(.+)\.t$/)[0];
}

sub _default_fixture_paths {
	my ($class) = @_;
	my $script_path = Path::Class::file($class->_script_path);
	my $script_dir = $script_path->dir;
	my @dir_parts = $script_dir->dir_list(1);

	return [
		Path::Class::file(qw/t etc fixtures/),
		Path::Class::file(qw/t etc fixtures/, @dir_parts, $script_path->basename),
	];

}

sub _default_paths {
	my ($class) = @_;
	my $script_path = Path::Class::file($class->_script_path);
	my $script_dir = $script_path->dir;
	my @dir_parts = $script_dir->dir_list(1);

	return [
		Path::Class::file(qw/t etc schema/),
		Path::Class::file(qw/t etc /, @dir_parts, $script_path->basename),
	];
}

sub _initialize_schema {
	my $class = shift @_;
	my $config  = shift @_;
	my $builder = __PACKAGE__->builder;
	my $schema_manager;

	eval {
		$schema_manager = Test::DBIx::Class::SchemaManager->initialize_schema(
			%$config, 
			builder => $builder,
		);
	}; if ($@) {
		Test::More::fail("Can't initialize a schema with the given configuration");
		Test::More::diag(
			Test::More::explain("configuration: " => $config)
		);
		$builder->skip_all("Skipping remaining tests since we don't have a schema");
	}

	return $schema_manager
}

1;

__END__

=head1 NAME

Test::DBIx::Class - Easier test cases for your L<DBIx::Class> applications

=head1 SYNOPSIS

The following is example usage for this module.  Assume you create a standard
Perl testing script, such as "MyApp/t/schema/01-basic.t" which is run from the
shell like "prove -l t/schema/01-basic.t" or during "make test".  That test 
script could contain:

	use Test::More; {

		use strict;
		use warnings;

		use Test::DBIx::Class {
			schema_class => 'MyApp::Schema',
			connect_info => ['dbi:SQLite:dbname=:memory:','',''],
			fixture_class => '::Populate',
			fixture_providers => [
				'::File' => {
					path => [ 
						[qw/t etc fixtures/], 
						[qw/t etc schema 01-basic/], 
					],
				},
			],
		}, 'Person', 'Person::Employee' => {-as => 'Employee'}, 'Job', 'Phone';

		## Your testing code below ##

		## Your testing code above ##

		done_testing();
	}

Yes, it looks like a lot of boilerplate, but sensible defaults are in place 
(the above code example shows most of the existing defaults) and configuration
data can be loaded from a central file.  So your 'real life' example is going
to look closer to (assuming you put all your test configuration in the standard
place, "t/etc/schema.conf":

	use Test::More; {
		
		use strict;
		use warnings;
		use Test::DBIx::Class;

		## Your testing code below ##
		## Your testing code above ##

		done_testing();
	}

Then, assuming the existance of a L<DBIx::Class::Schema> subclass called, 
"MyApp::Schema" and some L<DBIx::Class::ResultSources> named like "Person", 
"Person::Employee", "Job" and "Phone", will automatically deploy a testing 
schema in the given database / storage (or auto deploy to an in memory based
L<DBD::SQLite> database), install fixtures and let you run some test cases, 
such as:

		## Your testing code below ##

		fixtures_ok 'basic'
		  => 'installed the basic fixtures from configuration files';

		fixtures_ok { 
			Job => [
				[qw/name description/],
				[Programmer => 'She whow writes the code'],
				['Movie Star' => 'Knows nothing about the code'],
			],
		}, 'Installed some custom fixtures via the Populate fixture class',

		
		ok my $john = Person->find({email=>'jjnapiork@cpan.org'})
		  => 'John has entered the building!';

		is_fields $john, {
			name => 'John Napiorkowski', 
			email => 'jjnapiork@cpan.org', 
			age => 40,
		}, 'John has the expected fields';

		is_fields ['job_title'], $john->jobs, [
			{job_title => 'programmer'},
			{job_title => 'administrator'},
		], 
		is_fields 'job_title', $john->jobs, 
			[qw/programmer administrator/],
			'Same test as above, just different compare format;


		is_fields [qw/job_title salary/], $john->jobs, [
			['programmer', 100000],
			['administrator, 120000],
		], 'Got expected fields from $john->jobs';

		is_fields [qw/name age/], $john, ['John Napiorkowski', 40],
		  => 'John has expected name and age';

		is_fields_multi 'name', [
			$john, ['John Napiorkowski'],
			$vanessa, ['Vanessa Li'],
			$vincent, ['Vincent Zhou'],
		] => 'All names as expected';

		is_fields 'fullname', 
			ResultSet('Country')->find('USA'), 
			'United States of America',
			'Found the USA';

		is_deeply [sort Schema->sources], [qw/
			Person Person::Employee Job Country Phone
		/], 'Found all expected sources in the schema';

		fixtures_ok my $first_album = sub {
			my $schema = shift @_;
			my $cd_rs = $schema->resultset('CD');
			return $cd_rs->create({
				name => 'My First Album',
				track_rs => [
					{position=>1, title=>'the first song'},
					{position=>2, title=>'yet another song'},
				],
				cd_artist_rs=> [
					{person_artist=>{person => $vanessa}},
					{person_artist=>{person => $john}},
				],
			});
		}, 'You can even use a code reference for custom fixtures';

		## Your testing code above ##

Please see the test cases for more examples.

=head1 DESCRIPTION

The goal of this distribution is to make it easier to write test cases for your
L<DBIx::Class> based applications.  It does this in three ways.  First, it trys
to make it easy to deploy your Schema to a test sandbox.  This can be to your
dedicated testing database, a simple SQLite database, or even a MySQL Sandbox.
This allows you to run tests without interfering with your development work.

Second, we allow you to load test fixtures via several different tools.  Last
we create some helper functions in your test script so that you can reduce
repeated or boilerplate code.

Overall, we attempt to reduce the amount of code you have to write before you
can begin writing tests.

=head1 IMPORTED METHODS

The following methods are automatically imported when you use this module.

=head2 Schema

You probably won't need this directly in your tests unless you have some
application logic methods in it.


=head2 ResultSet ($source, ?{%search}, ?{%conditions})

Although you can import your sources as local keywords, sometimes you might
need to get a particular resultset when you don't wish to import it globally.
Use like

	ok ResultSet('Job'), "Yeah, some jobs in the database";
	ok ResultSet( Job => {hourly_pay=>{'>'=>100}}), "Good paying jobs available!";

Since this returns a normal L<DBIx::Class::ResultSet>, you can just call the
normal methods against it.

	ok ResultSet('Job')->search({hourly_pay=>{'>'=>100}}), "Good paying jobs available!";

This is the same as the test above.

=head2 fixtures_ok

This is used to install and verify installation of fixtures, either inlined,
from a fixture set in a file, or through a custom sub reference.  Accept three
argument styles:

=over 4

=item coderef

Given a code reference, execute it against the currently defined schema.  This
is used when you need a lot of control over installing your fixtures.  Example:

	fixtures_ok sub {
		my $schema = shift @_;
		my $cd_rs = $schema->resultset('CD');
		return $cd_rs->create({
			name => 'My First Album',
			track_rs => [
				{position=>1, title=>'the first song'},
				{position=>2, title=>'yet another song'},
			],
			cd_artist_rs=> [
				{person_artist=>{person => $vanessa}},
				{person_artist=>{person => $john}},
			],
		});

	}, 'Installed fixtures';

The above gets executed at runtime and if there is an error it is trapped,
reported and we move on to the next test.

=item hashref

Given a hash reference, attempt to process it via the default fixtures loader
or through the specified loader.

	fixtures_ok {
		Person => [
			['name', 'age', 'email'],
			['John', 40, 'john@nowehere.com'],
			['Vincent', 15, 'vincent@home.com'],
			['Vanessa', 35, 'vanessa@school.com'],
		],
	}, 'Installed fixtures';

This is a good option to use while you are building up your fixture sets or
when your sets are going to be small and not reused across lots of tests.  This
will get you rolling without messing around with configuration files.

=item fixture set name

Given a fixture name, or array reference of names, install the fixtures.

	fixtures_ok 'core';
	fixtures_ok [qw/core extra/];

Fixtures are installed in the order specified.

=back

All different types can be mixed and matched in a given test file.

=head2 is_result ($result, ?$result)

Quick test to make sure $result does inherit from L<DBIx::Class> or that it
inherits from a subclass of L<DBIx::Class>.

=head2 is_resultset ($resultset, ?$resultset)

Quick test to make sure $resultset does inherit from L<DBIx::Class::ResultSet>
or from a subclass of L<DBIx::Class::ResultSet>.

=head2 eq_resultset ($resultset, $resultset, ?$message)

Given two ResultSets, determine if the are equal based on class type and data.
This is a true set equality that ignores sorting order of items inside the
set.

=head2 eq_result ($resultset, $resultset, ?$message)

Given two row objects, make sure they are the same.

=head2 hri_dump ($resultset)

Not a test, just returns a version of the ResultSet that has its inflator set
to L<DBIx::Class::ResultClass::HashRefInflator>, which returns a set of hashes
and makes it easier to stop issues.  This return value is suitable for dumping
via L<Data::Dump>, for example.

=head2 reset_schema

Wipes and reloads the schema.

=head2 dump_settings

Returns the configuration and related settings used to initialize this testing
module.  This is mostly to help you debug trouble with configuration and to help
the authors find and fix bugs.  At some point this won't be exported by default
so don't use it for your real tests, just to help you understand what is going
on.  You've been warned!

=head2 is_fields

A 'Swiss Army Knife' method to check your results or resultsets.  Tests the 
values of a Result or ResultSet against expected via a pattern.  A pattern
is automatically created by instrospecting the fields of your ResultSet or
Result.

Example usage for testing a result follows.

	ok my $john = Person->find('john');

	is_fields 'name', $john, ['John Napiorkowski'],
	  'Found name of $john';

	is_fields [qw/name age/], $john, ['John Napiorkowski', 40],
	  'Found $johns name and age';

	is_fields $john, {
		name => 'John Napiorkowski',
		age => 40,
		email => 'john@home.com'};  # Assuming $john has only the three columns listed

In the case were we need to infer the match pattern, we get the columns of the
given result but remove the primary key.  Please note the following would also
work:

	is_fields [qw/name age/] $john, {
		name => 'John Napiorkowski',
		age => 40}, 'Still got the name and age correct'; 

You should choose the method that makes most sense in your tests.

Example usage for testing a resultset follows.

	is_fields 'name', Person, [
		'John',
		'Vanessa',
		'Vincent',
	];

	is_fields ['name'], Person, [
		'John',
		'Vanessa',
		'Vincent',
	];

	is_fields ['name','age'], Person, [
		['John',40],
		['Vincent',15],
		['Vanessa',35],
	];

	is_fields ['name','age'], Person, [
		{name=>'John', age=>40},
		{name=>'Vanessa',age=>35},
		{name=>'Vincent', age=>15},
	];

I find the array version is most consise.  Please note that the match is not
ordered.  If you need to test that a given Resultset is in a particular order,
you will currently need to write a custom test.  If you have a big need for 
this I'd be willing to write a test for it, or gladly accept a patch to add it.

You should examine the test cases for more examples.

=head2 is_fields_multi

	TBD: Not yet written.  Intended to be a version of 'is_fields that
	supports an array of items.

=head1 SETUP AND INITIALIZATION

The generic usage for this would look like one of the following:

	use Test::DBIx::Class \%options, @sources
	use Test::DBIx::Class %options, @sources

Where %options are key value pairs and @sources an array as specified below.

=head2 Initialization Options

The only difference between the hash and hash reference version of %options
is that the hash version requires its keys to be prepended with "-".  If
you are inlining a lot of configuration the hash reference version may look
neater, while if you are only setting one or two options the hash version
might be more readable.  For example, the following are the same:

	use Test::DBIx::Class -config_path=>[qw(t etc config)], 'Person', 'Job';
	use Test::DBIx::Class {config_path=>[qw(t etc config)]}, 'Person', 'Job';

The following options are currently defined.

=over 4

=item config_path

These are the relative paths searched for configuration file information. See
L</Initialization Sources> for more.

In the case were we have both inlined and file based configurations, the 
inlined is merged last (that is, has highest authority to override configuration
files.

When the final merging of all configurations (both anything inlined at 'use'
time, and anything found in any of the specified config_paths, we do a single
'post' config_path check.  This allows you to add in a configuration file from
inside a configuration file.  For safty and sanity you can only do this once.
This feature makes it easier to globalize any additional configuration files.
For example, I often store user specific settings in "~/etc/conf.*".  This
feature allows me to add that into my standard "t/etc/schema.*" so it's 
available to all my test cases.

=item schema_class

Required.  If left blank, will look down the lib path for a module called,
"Schema.pm" or "Store.pm" and attempt to use that.

=item connect_info

Required. This will accept anything you can send to L<DBIx::Class/connect>.
Defaults to: ['dbi:SQLite:dbname=:memory:','',''] if left blank.

=item fixture_path

These are a list of relative paths search for fixtures.  Each item should be
a directory that contains files loadable by L<Config::Any> and suitable to
be installed via one of the fixture classes.

=item fixture_class

Command class that installs data into the database.  Must provide a method
called 'install_fixtures' that accepts a perl data structure and installs
it into the database.  Must capture and report errors.  Default value is
"::Populate", which loads L<Test::DBIx::Class::FixtureClass::Populate>, which
is a command class based on L<DBIx::Class::Schema/populate>.

=item resultsets

Lets you add in some result source definitions to be imported at test script
runtime.  See L</Initialization Sources> for more.

=back

=head2 Initialization Sources

The @sources are a list of result sources that you want helper methods injected
into your test script namespace.  This is the 'Source' part of:

	$schema->resultset('Source');

Injecting methods are optional since you can also use the 'ResultSet' keyword

Imported Source keywords use L<Sub::Exporter> so you have quite a few options
for controling how the keywords are imported.  For example:

	use Test::DBIx::Class 
		'Person',
		'Person::Employee' => {-as => 'Employee'},
		'Person' => {search => {age=>{'>'=>55}}, -as => 'OlderPerson'};

This would import three local keywork methods, "Person", "Employee" and 
"OlderPerson".  For "OlderPerson", the search parameter would automatically be
resolved via $resultset->search and the correct resultset returned.  You may
wish to preconfigure all your test result set cases in one go at the top of
your test script as a way to promote reusability.

In addition to the 'search' parameter, there is also an 'exec' parameter
which let's you process your resultset programatically.  For example:

	'Person' => {exec => sub { shift->older_than(55) }, -as => 'OlderPerson'};

This code reference gets passed the resultset object.  So you can use any 
method on $resultset.  For example:

	'Person' => {exec => sub { shift->find('john') }, -as => 'John'}; 

	is_result John;
	is John->name, 'John Napiorkowski', "Got Correct Name";

Although since fixtures will not yet be installed, the above is probably not
going to be a normally working example :)

Additionally, since you can also initialize sources via the 'resultsets'
configuration option, which can be placed into your global configuration files
this means you can predefine and result resultsets across all your tests.  Here
is an example 't/etc/schema.pl' file where I initialize pretty much everything
in one file:

	 {
	  'schema_class' => 'Test::DBIx::Class::Example::Schema',
	  'resultsets' => [
		'Person',
		'Job',
		'Person' => { '-as' => 'NotTeenager', search => {age=>{'>'=>18}}},
	  ],
	  'fixture_sets' => {
		'basic' => {
		  'Person' => [
			[
			  'name',
			  'age',
			  'email'
			],
			[
			  'John',
			  '40',
			  'john@nowehere.com'
			],
			[
			  'Vincent',
			  '15',
			  'vincent@home.com'
			],
			[
			  'Vanessa',
			  '35',
			  'vanessa@school.com'
			]
		  ]
		}
	  },
	};

In this case you can simple do "use Test::DBIx::Class" and everything will
happen automatically.

=head1 CONFIGURATION BY FILE

By default, we try to load configuration fileis from the following locations:

	 ./t/etc/schema.*
	 ./t/etc/[test file path].*

Where "." is the root of the distribution and "*" is any of the configuration
file types supported by L<Config::Any> configuration loader.  This allows you
to store configuration in the format of your choice.

"[test file path]" is the relative path part under the "t" directory of the
calling test script.  For example, if your test script is "t/mytest.t" we add
the path "./t/etc/schema/mytest.*" to the path.

Additionally, we do a a merge using L<Hash::Merge> of all the matching found
configurations.  This allows you to do 'cascading' configuration from the most
global to the most local settings.

You can override this search path with the "-config_path" key in options. For
example, the following searches for "t/etc/myconfig.*" (or whatever is the
correct directory separator for your operating system):

	use Test::DBIx::Class -config_path => [qw/t etc myconfig/];

Relative paths are rooted to the distribution home directory (ie, the one that
contains your 'lib' and 't' directories).  Full paths are searched without
modification.

You can specify multiply paths.  The following would search for both "schema.*"
and "share/schema".

	use Test::DBIx::Class -config_path => [[qw/share schema/], [qw/schema/]];

Lastly, you can use the special symbol "+" to indicate that your custom path
adds to or prepends to the default search path.  Since as indicated we merge
all the configurations found, this means it's easy to create user level 
configuration settings mixed with global settings, as in:

	use Test::DBIx::Class
		-config_path => [ 
			[qw(/ etc myapp test-schema)],
			'+',
			[qw(~ etc test-schema)],
		];

Which would search and combine "/etc/myapp/test-schema.*", "./t/etc/schema.*",
"./etc/test-dbix-class.*" and "~/etc/test-schema.*".  This would let you set
up server level global settings, distribution level settings and finally user
level settings.

Please note that in all the examples given, paths are written as an array
reference of path parts, rather than as a string with delimiters (i.e. we do
[qw(t etc)] rather than "t/etc").  This is not required but recommended.  All
arguments, either string or array references, are passed to L<Path::Class> so
that we can maintain better compatibility with non unix filesystems.  If you
are writing for CPAN, please consider our non Unix filesystem friends :) 

=head1 EXAMPLES

The following are some additional examples using this module.

	TBD

=head1 SEE ALSO

The following modules or resources may be of interest.

L<DBIx::Class>, L<DBIx::Class::Schema::PopulateMore>, L<DBIx::Class::Fixtures>

=head1 AUTHOR

John Napiorkowski C<< <jjnapiork@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009, John Napiorkowski C<< <jjnapiork@cpan.org> >>

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
