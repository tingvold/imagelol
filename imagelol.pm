#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use POSIX qw(strftime);
use Config::General;
use Fcntl qw(:flock);

# Define imagelol-dir, and add it to %INC
my $imagelol_dir;
BEGIN {
	use FindBin;
	$imagelol_dir = "$FindBin::Bin"; # Assume working-folder is the path where this script resides
}
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
						(imagename, path_original, imagedate, category, path_preview, imagenumber)

					VALUES 	(?, ?, ?, ?, ?, ?)	
				",
	get_images =>		"	SELECT	*
	
					FROM	images
				",
	set_imagenumber =>	"	UPDATE 	images

					SET 	imagenumber = (?)

					WHERE 	(imageid = ?)
				",
	get_album =>		"	SELECT 	*

					FROM 	albums

					WHERE 	((LOWER(name)) = (LOWER(?)))
				",
	get_albums =>		"	SELECT 	*,
						(
							SELECT 	COUNT (*)
							FROM	album_images ai
							WHERE	a.albumid = ai.albumid
						) AS image_count

					FROM 	albums a
				",
	disable_album_ranges =>	"	UPDATE 	album_ranges

					SET 	enabled = false

					WHERE 	(albumid = ?)
				",
	get_album_ranges =>	"	SELECT	*
	
					FROM	album_ranges
					
					WHERE	(albumid = ?)
						AND (enabled = true)
				",
	add_album_range =>	"	INSERT	INTO album_ranges
						(imagerange, albumid, path_search, category)
						
					VALUES	(?, ?, ?, ?)
				",
	get_album_images =>	"	SELECT	*

					FROM	images i
						INNER JOIN album_images ai ON i.imageid = ai.imageid
					
					WHERE	(ai.albumid = ?)
				",
				
	delete_album_image =>	"	DELETE 	FROM album_images

					WHERE 	(imageid = ?)
						AND (albumid = ?)
				",
	add_album_image =>	"	INSERT	INTO album_images
						(imageid, albumid)

					VALUES	(?, ?)
				",
	set_album_desc =>	"	UPDATE 	albums

					SET 	description = (?)

					WHERE 	(albumid = ?)
				",
	set_album_parent =>	"	UPDATE 	albums

					SET 	parent = (nullif(?, '')::int)

					WHERE 	(albumid = ?)
				",
	add_album =>		"	INSERT	INTO albums
						(name, description, parent)

					VALUES	(?, ?, ?)
				",
	album_count =>		"	SELECT	COUNT (*)

					FROM	albums

					WHERE	(albumid = ?)
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

# Returns YYYY/MM
sub date_string_ym{
	return POSIX::strftime("%Y/%m", localtime(time()));
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
		my $connect_string = "DBI:Pg:";
		$connect_string .= "dbname=$config{db}->{database};";
		$connect_string .= "host=$config{db}->{hostname};";
		$connect_string .= "port=$config{db}->{port};";
		$connect_string .= "sslmode=require";
		
		$self->{_dbh} = DBI->connect(	$connect_string,
						$config{db}->{username},
						$config{db}->{password}, 
						{
							'RaiseError' => 0,
							'AutoInactiveDestroy' => 1
						}) 
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
		(system("$config{binaries}->{chmod} -R $mask \"$dst\"") == 0) or return 0;
	} else {
		(system("$config{binaries}->{chmod} $mask \"$dst\"") == 0) or return 0;
	}
	
	return 1;
}

# Chown
sub system_chown{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my ($dst, $uid, $gid, $recursive) = @_;
	
	if ($recursive){
		(system("$config{binaries}->{chown} -R $uid:$gid \"$dst\"") == 0) or return 0;
	} else {
		(system("$config{binaries}->{chown} $uid:$gid \"$dst\"") == 0) or return 0;
	}
	
	return 1;
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
	(system("$config{binaries}->{scp} $parameters \"$src\" \"$dest\"") == 0) or return 0;
	return 1;
}

# rm
sub system_rm{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($dst, $recursive) = @_;
	$recursive = 0; # we don't really want this
	
	if ($recursive){
		(system("$config{binaries}->{rm} -rf \"$dst\" 2> /dev/null") == 0) or return 0;
	} else {
		(system("$config{binaries}->{rm} \"$dst\" 2> /dev/null") == 0) or return 0;
	}
	return 1;
}

# Copies stuff
sub copy_stuff{
	my $self = shift;
	my ($source, $dest) = @_;
	
	debug_log("Copying '$source' to '$dest'...");
	(system("$config{binaries}->{cp} -p \"$source\" \"$dest\"") == 0) or return 0;
	return 1;
}

# Create dir
sub system_mkdir{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my $dir = "@_";
	
	(system("$config{binaries}->{mkdir} -p \"$dir\"") == 0) or return 0;
	return 1;
}

# Find all symlinked files
sub system_find_symlinks{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my $dir = "@_";
	
	my @symlinks = `$config{binaries}->{find} \"$dir\" -type l`;
	
	return @symlinks;
}

# Make symlink
sub system_ln{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	my ($source, $dest) = @_;
	
	(system("$config{binaries}->{ln} -s \"$source\" \"$dest\"") == 0) or return 0;
	return 1;
}

# Resize image
sub resize_image{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($width, $height, $src, $dst) = @_;
	
	(system("$config{binaries}->{convert} -geometry ${width}x${height} \"$src\" \"$dst\"") == 0) or die("Could not resize image '$src'...");
}

# Rotate image
sub rotate_image{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($src, $dst) = @_;
	
	(system("$config{binaries}->{convert} -auto-orient \"$src\" \"$dst\"") == 0) or die("Could not rotate image '$src'...");
}

# Convert PSD
sub convert_psd{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($src, $dst) = @_;
	
	(system("$config{binaries}->{convert} \"$src\"[0] \"$dst\"") == 0) or die("Could not convert PSD file '$src'...");
}

# Copy EXIF info
sub copy_exif{
	if ($_[0] =~ m/HASH/){
		#Value is a reference on an anonymous hash
		shift; # Remove class that is passed to the subroutine
	}
	
	my ($src, $dst) = @_;
	
	(system("$config{binaries}->{exiftool} -m -q -overwrite_original -tagsfromfile \"$src\" --makernotecanon \"$dst\"") == 0) or die("Could not copy EXIF-info from '$src' to '$dst'...");
}

# Add image to database
sub add_image{
	my $self = shift;
	my ($imagename, $original_path, $imagedate, $category, $preview_path, $imagenumber) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{add_image});
	$self->{_sth}->execute($imagename, $original_path, $imagedate, $category, $preview_path, $imagenumber);
	$self->{_sth}->finish();
	
	if($self->{_sth}->err){
		error_log("imagelol", "Something went wrong when trying to add image '$imagename' to DB; $self->{_sth}->errstr");
		return 0;
	} else {
		return 1;
	}
}

# Get range of images
sub get_image_range{
	my $self = shift;
	my ($img_range, $path_search, $category) = @_;
	my $query = qq( SELECT * FROM images WHERE ((LOWER(path_original)) LIKE (LOWER('%$path_search%'))) );
	$query .= qq( AND ( (LOWER(category)) = (LOWER('$category')) ) );
	$query .= 'AND (';
	
	my $first = 1;
	my $valid_ranges = 0;
	my @img_ranges = split(',', $img_range);
	foreach my $range (@img_ranges){
		$range =~ s/\s+//g; # remove whitespace
		if($range =~ m/^$config{regex}->{range}$/){
			# a range, XXXX-YYYY
			my ($range_start, $range_end) = split('-', $range);
			if($range_start == $range_end){
				# range start and end is the same
				# this is the same as a single image
				if($first){
					$query .= qq( (imagenumber = $range_start) );
					$first = 0;
				} else {
					$query .= qq( OR (imagenumber = $range_start) );
				}
				$valid_ranges++;
			} elsif($range_start > $range_end){
				# start is bigger than end, lets ignore
				log_it("imagelol", "'$range' starts with bigger number than what it ends with. Ignoring.");
				next;
			} else {
				# Only scenario here should be if $range_end is bigger than $range_start
				# This is how it should be, so we proceed.
				if($first){
					$query .= qq( (imagenumber BETWEEN $range_start AND $range_end) );
					$first = 0;
				} else {
					$query .= qq( OR (imagenumber BETWEEN $range_start AND $range_end) );
				}
				$valid_ranges++;
			}
		} elsif ($range =~ m/^$config{regex}->{single}$/){
			# single image
			if($first){
				$query .= qq( (imagenumber = $range) );
				$first = 0;
			} else {
				$query .= qq( OR (imagenumber = $range) );
			}
			$valid_ranges++;
		} else {
			# not valid
			log_it("imagelol", "'$range' is not a valid IMG-range. Ignoring.");
			next;
		}
	}
	
	unless($valid_ranges > 0){
		error_log("imagelol", "No valid ranges.");
		return 0;
	}
	
	$query .= ' ) ORDER BY imagenumber ASC';
		
	$self->{_sth} = $self->{_dbh}->prepare($query);
	$self->{_sth}->execute();
	
	my $images = $self->{_sth}->fetchall_hashref("imageid");
	$self->{_sth}->finish();
	
	return $images;
}

# Fetch album info
sub get_album{
	my $self = shift;
	my $album = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{get_album});
	$self->{_sth}->execute($album);
	
	my $albuminfo = $self->{_sth}->fetchrow_hashref();
	$self->{_sth}->finish();
	
	return $albuminfo;
}

# Get all albums
sub get_albums{
	my $self = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{get_albums});
	$self->{_sth}->execute();
	
	my $albums = $self->{_sth}->fetchall_hashref("albumid");
	$self->{_sth}->finish();
	
	return $albums;
}

# Get all images
sub get_images{
	my $self = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{get_images});
	$self->{_sth}->execute();
	
	my $images = $self->{_sth}->fetchall_hashref("imageid");
	$self->{_sth}->finish();
	
	return $images;
}

# Set imagenumber
sub set_imagenumber{
	my $self = shift;
	my ($imageid, $imagenumber) = @_;

	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{set_imagenumber});
	$self->{_sth}->execute($imagenumber, $imageid);
	$self->{_sth}->finish();
	
	# my $images = $imagelol->get_images();
	# 
	# foreach my $image ( sort keys %$images ){
	# 	(my $imagenumber = $images->{$image}->{imagename}) =~ s/^IMG_([0-9]+)\.CR2$/$1/;
	# 	print "Setting imagenumber ($images->{$image}->{imagename} -> $imagenumber)\n";
	# 	$imagelol->set_imagenumber($image, $imagenumber);
	# }
}

# Disable all album ranges
sub disable_album_ranges{
	my $self = shift;
	my $albumid = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{disable_album_ranges});
	$self->{_sth}->execute($albumid);
	$self->{_sth}->finish();
}

# Get all enabled album ranges
sub get_album_ranges{
	my $self = shift;
	my $albumid = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{get_album_ranges});
	$self->{_sth}->execute($albumid);
	
	my $ranges = $self->{_sth}->fetchall_hashref("rangeid");
	$self->{_sth}->finish();
	
	return $ranges;
}

# Add album range
sub add_album_range{
	my $self = shift;
	my ($albumid, $img_range, $path_search, $category) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{add_album_range});
	$self->{_sth}->execute($img_range, $albumid, $path_search, $category);
	$self->{_sth}->finish();
}

# Get images for an album
sub get_album_images{
	my $self = shift;
	my $albumid = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{get_album_images});
	$self->{_sth}->execute($albumid);
	
	my $images = $self->{_sth}->fetchall_hashref("imageid");
	$self->{_sth}->finish();
	
	return $images;
}

# Delete image
sub delete_album_image{
	my $self = shift;
	my ($imageid, $albumid) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{delete_album_image});
	$self->{_sth}->execute($imageid, $albumid);
	$self->{_sth}->finish();
}

# Add image
sub add_album_image{
	my $self = shift;
	my ($imageid, $albumid) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{add_album_image});
	$self->{_sth}->execute($imageid, $albumid);
	$self->{_sth}->finish();
}

# Add album
sub add_album{
	my $self = shift;
	my ($album_name, $album_description, $parent_albumid) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{add_album});
	$self->{_sth}->execute($album_name, $album_description, $parent_albumid);
	my $albumid = $self->{_dbh}->last_insert_id(undef,undef,undef,undef,{sequence=>'albums_albumid_seq'});
	$self->{_sth}->finish();
	
	return $albumid;
}

# Change album description
sub set_album_description{
	my $self = shift;
	my ($albumid, $album_description) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{set_album_desc});
	$self->{_sth}->execute($album_description, $albumid);
	$self->{_sth}->finish();
}

# Album exists
# Should only be 0 or 1, since albumid has unique-constraints
sub album_exists{
	my $self = shift;
	my $albumid = shift;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{album_count});
	$self->{_sth}->execute($albumid);
	
	my $album_count = ($self->{_sth}->fetchrow_array)[0];
	$self->{_sth}->finish();
	
	return $album_count;
}

# Change album parent
sub set_album_parent{
	my $self = shift;
	my ($albumid, $parent_id) = @_;
	
	$self->{_sth} = $self->{_dbh}->prepare($sql_statements->{set_album_parent});
	$self->{_sth}->execute($parent_id, $albumid);
	$self->{_sth}->finish();
}




1;