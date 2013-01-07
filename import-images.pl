#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use Image::ExifTool;
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
my ($src_dir, $dst_dir, $category);
if (@ARGV > 0) {
	GetOptions(
	's|src|source=s'	=> \$src_dir,
	'c|cat|category=s'	=> \$category,
	)
}

# Set paths from config, unless provided as parameter
if ($category){
	die error_log("Invalid category. Only numbers and letters allowed.") unless ($category =~ m/^[a-zA-Z0-9]$/);
}

$category = $config{path}->{default_category} unless $category;
$src_dir = $config{path}->{import_folder} unless $src_dir;
$dst_dir = $config{path}->{original_folder} . "/" . $category;

die error_log("Source directory doesn't exist. Exiting....") unless (-d $src_dir);

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
		my $exif_tags = Image::ExifTool::ImageInfo(	$image_full_path, { PrintConv => 0 },
								'DateTimeOriginal','PreviewImage','Rotation');
		die error_log("EXIF failed: $exif_tags->{Error}") if $exif_tags->{'Error'};

		my $date;
		if (defined($exif_tags->{'DateTimeOriginal'})){
			# We have a value
			# 'DateTimeOriginal' => '2012:12:31 17:50:01',
			
			if ($exif_tags->{'DateTimeOriginal'} =~ m/^[0-9]{4}\:[0-9]{2}\:[0-9]{2}\s+/){
				$date = (split(' ', $exif_tags->{'DateTimeOriginal'}))[0];
			}
		}
		
		unless ($date){
			# No (valid) date was found with EXIF
			# Using 'file created'
			
			# Last access:		stat($_)->atime
			# Last modify:		stat($_)->mtime
			# File creation:	stat($_)->ctime
			
			# Use YYYY:MM:DD, so that it's the same output as EXIF
			$date = POSIX::strftime("%Y:%m:%d", localtime(stat($image_full_path)->atime()));
		}		
		
		# At this point it should be safe to assume that $date has a value
		# And that it looks like YYYY:MM:DD
		my ($year, $month, $day) = split(':', $date);
		
		# We now know the dates when the file was created
		# Check if directory exists, if not, create it
		my $image_dst_dir = $dst_dir . "/" . $year . "/" . $month . "/" . $day;
		unless (-d $image_dst_dir){
			# create directory
			log_it("Creating directory '$image_dst_dir'...");
			$imagelol->system_mkdir($image_dst_dir);
		}
				
		# Check if destination image exists
		my $image_dst_file = $image_dst_dir . "/" . $image_file;
		die error_log("Destination file ($image_dst_file) exists. Aborting.") if (-e $image_dst_file);
		
		# Copy image
		log_it("Copying image '$image_full_path' to '$image_dst_file'...");
		$imagelol->copy_stuff($image_full_path, "$image_dst_dir/");
		
		# Extract preview
		# Save full version + resized version
		log_it("Extracting preview from RAW file...");

		# Exit if error
		die error_log("No preview found.") unless defined($exif_tags->{'PreviewImage'});

		# Fetch JPG
		my $jpg_from_raw = $exif_tags->{'PreviewImage'};
		$jpg_from_raw = $$jpg_from_raw if ref($jpg_from_raw);

		# Create dir
		my $preview_dst_dir = $config{path}->{preview_folder} . "/" . $category . "/" . $year . "/" . $month . "/" . $day;
		unless (-d $preview_dst_dir){
			# create directory
			log_it("Creating directory '$preview_dst_dir'...");
			$imagelol->system_mkdir($preview_dst_dir);
		}

		# Make filename of previews
		(my $jpg_filename = $image_file) =~ s/\.[^.]+$//;
		my $jpg_filename_full = $jpg_filename . "-full" . ".jpg";
		my $jpg_filename_small = $jpg_filename . "-small" . ".jpg";
		
		my $jpg_dst_full = $preview_dst_dir . "/" . $jpg_filename_full;
		my $jpg_dst_small = $preview_dst_dir . "/" . $jpg_filename_small;
		
		# Copy full preview
		my $JPG_FILE;
		open(JPG_FILE,">$jpg_dst_full") or die error_log("Error creating '$jpg_dst_full'.");
		binmode(JPG_FILE);
		my $err;
		print JPG_FILE $jpg_from_raw or $err = 1;
		close(JPG_FILE) or $err = 1;
		if ($err) {
			unlink $jpg_dst_full; # remove the bad file
			die error_log("Could not copy preview image '$jpg_dst_full'. Aborting.");
		}
		
		# Copy EXIF-data from RAW, into preview
		my $exif = Image::ExifTool->new();
		my $info = $exif->SetNewValuesFromFile($image_full_path);
		my $result = $exif->WriteInfo($image_full_path, $jpg_dst_full);
		die error_log("Error copying EXIF-data: " . $exif->GetValue('Warning')) if $exif->GetValue('Warning');
		die error_log("Error copying EXIF-data: " . $exif->GetValue('Error')) if $exif->GetValue('Error');
		
		# Rotate full preview (if needed)
		$imagelol->rotate_image($jpg_dst_full, $jpg_dst_full);
		
		# Make resized preview
		$imagelol->resize_image($config{image}->{medium_width}, $config{image}->{medium_height}, $jpg_dst_full, $jpg_dst_small);
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
