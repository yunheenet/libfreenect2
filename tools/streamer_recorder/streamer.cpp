/*
 * This file is part of the OpenKinect Project. http://www.openkinect.org
 *
 * Copyright (c) 2017 individual OpenKinect contributors. See the CONTRIB file
 * for details.
 *
 * This code is licensed to you under the terms of the Apache License, version
 * 2.0, or, at your option, the terms of the GNU General Public License,
 * version 2.0. See the APACHE20 and GPL2 files for the text of the licenses,
 * or the following URLs:
 * http://www.apache.org/licenses/LICENSE-2.0
 * http://www.gnu.org/licenses/gpl-2.0.txt
 *
 * If you redistribute this file in source form, modified or unmodified, you
 * may:
 *   1) Leave this header intact and distribute it under the same terms,
 *      accompanying it with the APACHE20 and GPL20 files, or
 *   2) Delete the Apache 2.0 clause and accompany it with the GPL2 file, or
 *   3) Delete the GPL v2 clause and accompany it with the APACHE20 file
 * In all cases you must keep the copyright notice intact and include a copy
 * of the CONTRIB file.
 *
 * Binary distributions must follow the binary distribution requirements of
 * either License.
 */

#include "streamer.h"
#include <cstdlib>
#include <algorithm>

void Streamer::initialize()
{
  std::cout << "Initialize Streamer." << std::endl;

  jpegqual =  ENCODE_QUALITY; // Compression Parameter

  servAddress = SERVER_ADDRESS;
  servPort = Socket::resolveService(SERVER_PORT, "udp"); // Server port

  compression_params.push_back(cv::IMWRITE_JPEG_QUALITY);
  compression_params.push_back(jpegqual);
}

void Streamer::stream(libfreenect2::Frame* frame)
{
  try
  {
    cv::Mat frame_for_encode;
    if (frame->format == libfreenect2::Frame::Float)
    {
      frame_for_encode = cv::Mat(frame->height, frame->width, CV_32FC1, frame->data) / 10;
    }
    else if (frame->bytes_per_pixel == 4)
    {
      cv::Mat frame_4ch(frame->height, frame->width, CV_8UC4, frame->data);
      const int conversion_code = (frame->format == libfreenect2::Frame::RGBX)
        ? cv::COLOR_RGBA2BGR
        : cv::COLOR_BGRA2BGR;
      cv::cvtColor(frame_4ch, frame_for_encode, conversion_code);
    }
    else if (frame->bytes_per_pixel == 1)
    {
      frame_for_encode = cv::Mat(frame->height, frame->width, CV_8UC1, frame->data);
    }
    else
    {
      std::cerr << "Unsupported frame format for streaming. bpp=" << frame->bytes_per_pixel
                << " format=" << frame->format << std::endl;
      return;
    }

    cv::imencode(".jpg", frame_for_encode, encoded, compression_params);
    if (encoded.empty())
    {
      return;
    }

    // resize image
    // resize(frame, encoded, Size(FRAME_WIDTH, FRAME_HEIGHT), 0, 0, INTER_LINEAR);

    // show encoded frame
    // cv::namedWindow( "streamed frame", CV_WINDOW_AUTOSIZE);
    // cv::imshow("streamed frame", encoded);
    // cv::waitKey(0);

    total_pack = 1 + (encoded.size() - 1) / PACK_SIZE;

    // send pre-info
    ibuf[0] = total_pack;
    sock.sendTo(ibuf, sizeof(int), servAddress, servPort);

    // send image data packet
    for(int i = 0; i < total_pack; i++)
    {
      const size_t offset = static_cast<size_t>(i) * PACK_SIZE;
      const size_t remaining = encoded.size() - offset;
      const size_t chunk_size = std::min(static_cast<size_t>(PACK_SIZE), remaining);
      sock.sendTo(&encoded[offset], static_cast<int>(chunk_size), servAddress, servPort);
    }
  }
  catch (SocketException & e)
  {
    std::cerr << e.what() << std::endl;
    // exit(1);
  }
}
