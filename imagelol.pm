#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use POSIX qw(strftime);
use Config::General;
use Fcntl qw(:flock);

# Define imagelol-dir, and add it to %INC
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;

package imagelol;

# Load config
my $config_file = "$imagelol_dir/imagelol.conf";
my $conf = Config::General->new(
	-ConfigFile => $config_file,
	-InterPolateVars => 1);
my %config = $conf->getall;

# Internal switches
my $silent_logging = $config{switch}->{silent_logging};
my $simple_logging = $config{switch}->{simple_logging};

# Variables
my $LOG_FILE;
my $error = 0;

my $sql_statements = {
	add_image =>		"	INSERT 	INTO images
						(imagename, path, imagedate, category)

					VALUES 	(?, ?, ?, ?)	
				",
};

# Create class
sub new{
	my $self = {};
		
	my $logfile_name = $config{path}->{log_folder} . "/" . $config{path}->{logfile_prefix} . "_" . date_string_ymd();
		
	open $LOG_FILE, '>>', $logfile_name or die "Couldn't open $logfile_name: $!";
	
	# Fix permissions for the logfile
	# If the file is created while running as root, the imagelol-user cannot access it
	if (is_root()){
		system_chown($logfile_name, $config{div}->{imagelol_uid}, $config{div}->{imagelol_gid}, 0);
	}
		
	return bless $self, shift;
}

# Logs stuff to STDOUT and file
sub log_it{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}	
	
	my $script = shift;
	print $LOG_FILE date_string() . ": [$script] @_\n";
	unless ($silent_logging){
		if ($simple_logging){
			print "@_\n";
		} else {
			print date_string() . ": [$script] @_\n";
		}
	}
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}

	if ($config{switch}->{debug_log}){
		log_it(shift, "Debug: @_");
	}
}

# Logs error-stuff
sub error_log{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}

	$error = 1;
	log_it(shift, "Error: @_");
}

sub enable_silent_logging{
	$silent_logging = 1;
}

sub enable_simple_logging{
	$simple_logging = 1;
}

# Returns RFC822-formatted date-string
sub date_string{
	return POSIX::strftime("%a, %d %b %Y %H:%M:%S %z", localtime(time()));
}

# Returns YYYY-MM-DD
sub date_string_ymd{
	return POSIX::strftime("%Y-%m-%d", localtime(time()));
}

sub get_error_value{
	return $error;
}

# Fetch config-values
sub get_config{
	return %config;
}

# Prompts user for yes/no-question. If user says yes, it returns 1.
# If user says no, it returns 0.
sub prompt_yes_no{
	if (@_){
		if ($_[0] =~ m/HASH/){
			#Value is a reference on an anonymous hash
			shift; # Remove class that is passed to the subroutine
		}
	}
	
	my $prompt_string = "@_";
	
	while (1){
		print $prompt_string . " [y/n | yes/no]: ";
	
		chomp(my $input = <STDIN>);
		
		if ($input =~ m/^(y|yes)$/i){
			return 1;
		} elsif ($input =~ m/^(n|no)$/i){
			return 0;
		} else {
			print "Invalid input. Try again.\n";
		}
	}
}

# Returns 1 if current user is root, 0 otherwise
sub is_root{
	if (@_){
		if ($_[0] =~ m/HASH/){
			#Value is a reference on an anonymous hash
			shift; # Remove class that is passed to the subroutine
		}
	}
	my $uid = $<;
	my $username = getpwuid($uid);

	if (($uid == 0) or ($username eq "root")){
		# is root
		return 1;
	} else {
		return 0;
	}
}

# Connect to database
sub connect{
	my $self = shift;
	
	#if (pingable($config{db}->{hostname})){
	if (1){
		$self->{_dbh} = DBI->connect(	"DBI:Pg:dbname=$config{db}->{database};host=$config{db}->{hostname};port=$config{db}->{port};sslmode=require",
						"$config{db}->{username}", "$config{db}->{password}", {'RaiseError' => 0, 'AutoInactiveDestroy' => 1}) 
				or die log_it("imagelol", "Got error $DBI::errstr when connecting to database.");
	} else {
		error_log("imagelol", "Could not ping database-server.");
		exit 1;
	}
}

# Disconnect from database
sub disconnect{
	my $self = shift;
	$self->{_dbh}->disconnect();
}


# Chmod
sub system_chmod{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my ($dst, $mask, $recursive) = @_;
	
	if ($recursive){
		(system("$config{binaries}->{chmod} -R $mask $dst") == 0) or die("Could not chmod $dst.");
	} else {
		(system("$config{binaries}->{chmod} $mask $dst") == 0) or die("Could not chmod $dst.");
	}
}

# Chown
sub system_chown{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my ($dst, $uid, $gid, $recursive) = @_;
	
	if ($recursive){
		(system("$config{binaries}->{chown} -R $uid:$gid $dst") == 0) or die("Could not chown $dst.");
	} else {
		(system("$config{binaries}->{chown} $uid:$gid $dst") == 0) or die("Could not chown $dst.");
	}
}

# Scp
sub system_scp{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	# $parameters can be used to specify port (with -P), or other scp-parameters
	my ($src, $dest, $parameters) = @_;
	
	unless ($parameters){
		$parameters = "";
	}
	
	# NOTE: if this subroutine is to be used in a script that is run by the system automatically
	# f.ex. in a cron-job, it implies that the user the script is run as, has pubkeys (or other 
	# means of passwordless access to the host in question).
	(system("$config{binaries}->{scp} $parameters $src $dest") == 0) or die("Could not copy files with scp.");
}

# Copies stuff
sub copy_stuff{
	my $self = shift;
	my ($source, $dest) = @_;
	
	debug_log("Copying '$source' to '$dest'...");
	(system("$config{binaries}->{cp} -p $source $dest") == 0) or die error_log("Copy of file '$source' to '$dest' failed.");
}

# Create dir
sub system_mkdir{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my $dir = "@_";
	
	(system("$config{binaries}->{mkdir} -p $dir") == 0) or die("Could not create directory '$dir'.");
}

# Resize image
sub resize_image{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($width, $height, $src, $dst) = @_;
	
	(system("$config{binaries}->{convert} -geometry ${width}x${height} $src $dst") == 0) or die("Could not resize image '$src'...");
}

# Rotate image
sub rotate_image{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($src, $dst) = @_;
	
	(system("$config{binaries}->{convert} -auto-orient $src $dst") == 0) or die("Could not rotate image '$src'...");
}

# Copy EXIF info
sub copy_exif{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($src, $dst) = @_;
	
	(system("$config{binaries}->{exiftool} -q -overwrite_original -tagsfromfile $src --makernotecanon $dst") == 0) or die("Could not copy EXIF-info from '$src' to '$dst'...");
}

# Add image to database
sub db_add_image{
	my $self = shift;
	my ($dbh, $imagename, $path, $imagedate, $category) = @_;
	
	my $sth = $dbh->prepare($sql_statements->{add_image});
	$sth->execute($imagename, $path, $imagedate, $category);
	$sth->finish();
	undef($dbh);
	
	if($sth->err){
		error_log("imagelol", "Something went wrong when trying to add image '$imagename' to DB; $sth->errstr");
		return 0;
	} else {
		return 1;
	}
}





1;