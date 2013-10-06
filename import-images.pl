#!/usr/bin/perl	
use strict;
use warnings;
use lib "/opt/local/lib/perl5/site_perl/5.12.4";
use Getopt::Long;
use File::Find;
use Image::ExifTool;
use File::stat;
use threads;
use threads::shared;
use Thread::Queue;

# Load imagelol
my $imagelol_dir;
BEGIN { $imagelol_dir = "/srv/bilder/imagelol"; }
use lib $imagelol_dir;
use imagelol;
my $imagelol = imagelol->new();
my %config = $imagelol->get_config();

# Variables
my $max_threads = 5;			# Max threads to use
my $imageq = Thread::Queue->new(); 	# Queue to put image files in
#my $switches : shared = 0;		# Number of successful switches
#my $failed_switches : shared = 0;	# Number of failed switches
#my $total_time : shared = 0;		# Total time spent for all switches
#my %telnet_sessions : shared;		# Number of sessions currently in use

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

$category = $config{div}->{default_category} unless $category;
$src_dir = $config{path}->{import_folder} unless $src_dir;
$dst_dir = $config{path}->{original_folder} . "/" . $category;

die error_log("Source directory doesn't exist. Exiting.") unless (-d $src_dir);

# Find images
sub find_images{
	# Find and import all images
	find(\&image_queue, $src_dir);
}

# Add images to queue
sub image_queue{
	my %image = (
		full_path => "$File::Find::name",
		image_file => "$_",
	);
	
	# Add image to queue
	$imageq->enqueue(\%image);
}

# Copy images
sub process_images{
	while (my $image = $imageq->dequeue()){
		last if ($image eq 'DONE');	# all done
		
		if ($image->{image_file} =~ m/^.+\.($config{div}->{image_filenames})$/i){
			# We have a image (or, at least a filename that matches the image_filenames variable)

			# Is this a RAW image? (affects what we do with preview, etc)
			my $is_raw = 0;
			$is_raw = 1 if ($image->{image_file} =~ m/^.+\.($config{div}->{raw_image})$/i);

			# We need to figure out the date the picture was taken
			# First we try to use EXIF, and if that fails, we use the 'file created'
			my $exif_tags = Image::ExifTool::ImageInfo(	$image->{full_path}, { PrintConv => 0 },
									'DateTimeOriginal','PreviewImage','Orientation');
									### TODO, if the above fails, we need to fetch specific
									### tags depending on wether or not it's a raw file
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
				$date = POSIX::strftime("%Y:%m:%d", localtime(stat($image->{full_path})->ctime()));
			}		

			# At this point it should be safe to assume that $date
			# has a value, and that it looks like YYYY:MM:DD
			my ($year, $month, $day) = split(':', $date);

			# We now know the dates when the file was created
			# Check if directory exists, if not, create it
			my $image_dst_dir = $dst_dir . "/" . $year . "/" . $month . "/" . $day;
			unless (-d $image_dst_dir){
				# create directory
				log_it("Creating directory '$image_dst_dir'.");
				$imagelol->system_mkdir($image_dst_dir);
			}

			# Check if destination image exists
			my $image_dst_file = $image_dst_dir . "/" . $image->{image_file};
			die error_log("Destination file ($image_dst_file) exists. Aborting.") if (-e $image_dst_file);

			# Copy image
			log_it("Copying image '$image_full_path' to '$image_dst_file'.");
			$imagelol->copy_stuff($image->{full_path}, "$image_dst_dir/");

			# Extract preview
			# Save full version + resized version
			log_it("Extracting preview from RAW file.") if $is_raw;

			# Exit if error
			die error_log("No preview found.") unless defined($exif_tags->{'PreviewImage'});

			# Fetch JPG
			if ($is_raw){
				my $jpg_from_raw = $exif_tags->{'PreviewImage'};
				$jpg_from_raw = $$jpg_from_raw if ref($jpg_from_raw);
			}

			# Create dir
			my $preview_dst_dir = $config{path}->{preview_folder} . "/" . $category . "/" . $year . "/" . $month . "/" . $day;

			unless (-d $preview_dst_dir){
				# create directory
				log_it("Creating directory '$preview_dst_dir'.");
				$imagelol->system_mkdir($preview_dst_dir);
			}

			# Make filename of previews
			(my $jpg_filename = $image->{image_file}) =~ s/\.[^.]+$//;
			my $jpg_filename_full = $jpg_filename . "-full" . ".jpg";
			my $jpg_filename_small = $jpg_filename . "-small" . ".jpg";
							## TODO: Use 'full' for full, and then size for the resized one?
							## This way we can more easily add multiple image-sizes at a later point

			my $jpg_dst_full = $preview_dst_dir . "/" . $jpg_filename_full;
			my $jpg_dst_small = $preview_dst_dir . "/" . $jpg_filename_small;

			# Copy full preview
			if ($is_raw){
				# Extract preview from RAW file
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
			} else {
				# Copy normally, as source is non-RAW
				$imagelol->copy_stuff($image_full_path, $jpg_dst_full);
			}

			# Copy EXIF-data from source, into preview
			$imagelol->copy_exif($image->{full_path}, $jpg_dst_full);

			# Rotate full preview (if needed)
			# http://sylvana.net/jpegcrop/exif_orientation.html
			# http://www.impulseadventure.com/photo/exif-orientation.html
			# We do rotation unless 'orientation == 1'	
			my $rotate = 1;
			if (defined($exif_tags->{'Orientation'})){
				$rotate = 0 if ($exif_tags->{'Orientation'} == 1);
			}
			$imagelol->rotate_image($jpg_dst_full, $jpg_dst_full) if $rotate;

			# Make resized preview
			$imagelol->resize_image($config{image}->{medium_width}, $config{image}->{medium_height}, $jpg_dst_full, $jpg_dst_small);
		}
	}
	
  	# detach thread -- we're done
	threads->detach;
}

# We only want 1 instance of this script running
# Check if already running -- if so, abort.
unless (flock(DATA, LOCK_EX|LOCK_NB)) {
	die error_log("$0 is already running. Exiting.");
}

# Let's start...
my $time_start = time();

# Find all images, add to queue
find_images();

# Let the threads know when they're done
$imageq->enqueue("DONE") for (1..$max_threads);

# Start processing the queue
threads->create("process_images") for (1..$max_threads);

# Wait till all threads is done
sleep 5 while (threads->list(threads::running));

# How long did we run
my $runtime = time() - $time_start;
log_it("Took $runtime seconds to complete.");

__DATA__
Do not remove. Makes sure flock() code above works as it should.
