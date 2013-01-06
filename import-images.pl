#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use Image::ExifTool;
use Time::localtime;
use File::stat;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Log
sub log_it{
	$imagelol->log_it("import-images", "@_");
}

# Logs debug-stuff if debug has been turned on
sub debug_log{
	$imagelol->debug_log("import-images", "@_");
}

# Logs error-stuff
sub error_log{
	$imagelol->error_log("import-images", "@_");
}

# Get options
my ($src_dir, $dst_dir);
if (@ARGV > 0) {
	GetOptions(
	's|src|source=s'	=> \$src_dir,
	'd|dst|destination=s'	=> \$dst_dir,
	)
}

# Set paths from config, unless provided as parameter
$src_dir = $config{path}->{import_folder} unless $src_dir;
$dst_dir = $config{path}->{archive_folder} unless $dst_dir;

die error_log("Source directory doesn't exist. Exiting....") unless (-d $src_dir);
die error_log("Destination directory doesn't exist. Exiting....") unless (-d $dst_dir);

# Import images
sub import_images{
	# Find and import all images
	find(\&copy_images, $src_dir);
}

# Copy images
sub copy_images{
	my $image_full_path = "$File::Find::name";
	my $image_file = "$_";
	
	if ($image_file =~ m/^.+\.$config{div}->{image_filenames}$/i){
		# We have a image (or, at least a filename that matches the image_filenames variable)
		
		# We need to figure out the date the picture was taken
		# First we try to use EXIF, and if that fails, we use the 'file created'
		my $exif_date = Image::ExifTool::ImageInfo($image_full_path, { PrintConv => 0 }, 'DateTimeOriginal');
		die error_log("EXIF failed: $exif_date->{Error}") if $exif_date->{'Error'};

		my $date;
		if (defined($exif_date->{'DateTimeOriginal'})){
			# We have a value
			# 'DateTimeOriginal' => '2012:12:31 17:50:01',
			
			if ($exif_date->{'DateTimeOriginal'} =~ m/^[0-9]{4}\:[0-9]{2}\:[0-9]{2}\s+/){
				$date = (split(' ', $exif_date->{'DateTimeOriginal'}))[0];
			}
		}
		
		unless ($date){
			# No (valid) date was found with EXIF
			# Using 'file created'
			
			# Last access:		ctime(stat($_)->atime);
			# Last modify:		ctime(stat($_)->mtime);
			# File creation:	ctime(stat($_)->ctime);
			
			# Use YYYY:MM:DD, so that it's the same output as EXIF
			$date = POSIX::strftime("%Y:%m:%d", localtime(stat($image_full_path)->atime()));
		}
		
		# At this point it should be safe to assume that $date has a value
		# And that it looks like YYYY:MM:DD
		my ($year, $month, $day) = split(':', $date);
		
		# We now know the dates when the file was created
		# Check if directory exists, if not, create it
		my $image_dst_dir = $dst_dir . $year . $month . $day;
		unless (-d $image_dst_dir){
			# create directory
			log_it("Creating directory '$image_dst_dir'...");
			$imagelol->system_mkdir($image_dst_dir);
		}
				
		# Check if destination image exists
		die error_log("Destination file ($image_dst_dir/$image_file) exists. Aborting.") if (-e "$image_dst_dir/$image_file");
		
		# Copy image
		log_it("Copying image '$image_full_path' to '$image_dst_dir/$image_file'...");
		$imagelol->copy_stuff($image_full_path, "$image_dst_dir/");
	}
}

# We only want 1 instance of this script running
# Check if already running -- if so, abort.
unless (flock(DATA, LOCK_EX|LOCK_NB)) {
	die error_log("$0 is already running. Exiting.");
}

# Let's start...
my $time_start = time();

# Import images...
import_images();

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
