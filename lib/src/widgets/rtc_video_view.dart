import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

/// Widget for rendering remote user's video stream
///
/// This widget wraps ZEGO's video view to provide a clean API for the main app
class RtcRemoteVideoView extends StatefulWidget {
  /// The stream ID of the remote user
  final String streamId;

  /// View mode for the video (how it should be scaled)
  final ZegoViewMode viewMode;

  const RtcRemoteVideoView({
    super.key,
    required this.streamId,
    this.viewMode = ZegoViewMode.AspectFill,
  });

  @override
  State<RtcRemoteVideoView> createState() => _RtcRemoteVideoViewState();
}

class _RtcRemoteVideoViewState extends State<RtcRemoteVideoView> {
  Widget? _videoWidget;
  int? _canvasViewID;
  bool _hasStartedPlaying = false;
  bool _receivedFirstFrame = false;
  int _retryCount = 0;
  static const int _maxRetries = 60; // Retry for up to 30 seconds (60 attempts x 500ms)

  @override
  void initState() {
    super.initState();
    dev.log('[RtcRemoteVideoView] Initializing remote video view for stream: ${widget.streamId}');
    dev.log('[RtcRemoteVideoView] Will retry up to $_maxRetries times if stream not available');
    _setupVideoFrameMonitoring();
    _createVideoView();
  }

  /// Monitor for first video frame to confirm video is rendering
  void _setupVideoFrameMonitoring() {
    ZegoExpressEngine.onPlayerRecvVideoFirstFrame = (String streamID) {
      if (streamID == widget.streamId && !_receivedFirstFrame) {
        _receivedFirstFrame = true;
        dev.log('[RtcRemoteVideoView] 🎉🎉🎉 FIRST VIDEO FRAME RECEIVED for ${widget.streamId}!');
        dev.log('[RtcRemoteVideoView] ✅✅✅ CONFIRMED: Remote video is NOW RENDERING!');
      }
    };

    ZegoExpressEngine.onPlayerVideoSizeChanged = (String streamID, int width, int height) {
      if (streamID == widget.streamId) {
        dev.log('[RtcRemoteVideoView] 🎉 Video resolution: ${width}x${height} for ${widget.streamId}');
      }
    };
  }

  Future<void> _createVideoView() async {
    try {
      dev.log('[RtcRemoteVideoView] Creating canvas view for stream: ${widget.streamId}');

      final videoWidget = await ZegoExpressEngine.instance.createCanvasView((viewID) {
        dev.log('[RtcRemoteVideoView] Canvas created (viewID: $viewID)');
        _canvasViewID = viewID;

        // Try to start playing immediately (works if stream already exists)
        _startPlayingWithCanvas(viewID);
      });

      if (mounted) {
        setState(() {
          _videoWidget = videoWidget;
        });
        dev.log('[RtcRemoteVideoView] ✅ Remote video canvas widget created for stream: ${widget.streamId}');
      }
    } catch (e, stackTrace) {
      dev.log('[RtcRemoteVideoView] ❌ Error creating remote video view: $e', error: e, stackTrace: stackTrace);
    }
  }

  void _startPlayingWithCanvas(int viewID) {
    // Stop if we already received first frame (success!)
    if (_receivedFirstFrame) {
      dev.log('[RtcRemoteVideoView] ✅ Already receiving video frames, stopping retries');
      return;
    }

    // Check if we've exceeded max retries
    if (_retryCount >= _maxRetries) {
      dev.log('[RtcRemoteVideoView] ❌ Max retries (${_maxRetries}) reached after ${_maxRetries * 0.5} seconds');
      dev.log('[RtcRemoteVideoView] ❌ Stream ${widget.streamId} is not available');
      dev.log('[RtcRemoteVideoView] ❌ POSSIBLE CAUSES:');
      dev.log('[RtcRemoteVideoView]    1. User hasn\'t joined the ZEGO room yet');
      dev.log('[RtcRemoteVideoView]    2. User hasn\'t published their stream yet');
      dev.log('[RtcRemoteVideoView]    3. Stream ID mismatch');
      return;
    }

    _retryCount++;
    dev.log('[RtcRemoteVideoView] [Attempt $_retryCount/$_maxRetries] Trying to play stream: ${widget.streamId}');

    ZegoExpressEngine.instance.startPlayingStream(
      widget.streamId,
      canvas: ZegoCanvas(
        viewID,
        viewMode: widget.viewMode,
      ),
    ).then((_) {
      dev.log('[RtcRemoteVideoView] ✅ startPlayingStream API succeeded (attempt $_retryCount)');
      dev.log('[RtcRemoteVideoView] ⏳ Waiting for onPlayerRecvVideoFirstFrame callback to confirm actual video...');
    }).catchError((error) {
      dev.log('[RtcRemoteVideoView] ⚠️ startPlayingStream failed (attempt $_retryCount/$_maxRetries): $error');
    });

    // Schedule next retry in 500ms
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && !_receivedFirstFrame) {
        _startPlayingWithCanvas(viewID);
      }
    });
  }

  @override
  void dispose() {
    dev.log('[RtcRemoteVideoView] Disposing remote video view for stream: ${widget.streamId}');
    // Stop playing the stream when widget is disposed
    if (_hasStartedPlaying) {
      dev.log('[RtcRemoteVideoView] Stopping playback for stream: ${widget.streamId}');
      ZegoExpressEngine.instance.stopPlayingStream(widget.streamId).catchError((error) {
        dev.log('[RtcRemoteVideoView] Error stopping stream: $error');
      });
    }
    // Destroy the canvas view
    if (_canvasViewID != null) {
      dev.log('[RtcRemoteVideoView] Destroying canvas view: $_canvasViewID');
      ZegoExpressEngine.instance.destroyCanvasView(_canvasViewID!).catchError((error) {
        dev.log('[RtcRemoteVideoView] Error destroying canvas: $error');
        return false;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _videoWidget ?? Container(
      color: Colors.black,
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

/// Widget for rendering local user's video preview
///
/// This widget shows the user's own camera feed
class RtcLocalVideoView extends StatefulWidget {
  /// View mode for the video (how it should be scaled)
  final ZegoViewMode viewMode;

  const RtcLocalVideoView({
    super.key,
    this.viewMode = ZegoViewMode.AspectFill,
  });

  @override
  State<RtcLocalVideoView> createState() => _RtcLocalVideoViewState();
}

class _RtcLocalVideoViewState extends State<RtcLocalVideoView> {
  Widget? _videoWidget;
  int? _canvasViewID;

  @override
  void initState() {
    super.initState();
    dev.log('[RtcLocalVideoView] Initializing local video preview');
    _createVideoView();
  }

  Future<void> _createVideoView() async {
    try {
      dev.log('[RtcLocalVideoView] Creating canvas view for local preview');
      final videoWidget = await ZegoExpressEngine.instance.createCanvasView((viewID) {
        dev.log('[RtcLocalVideoView] Canvas created (viewID: $viewID), starting preview');
        _canvasViewID = viewID;
        // Start local preview with the canvas
        ZegoExpressEngine.instance.startPreview(
          canvas: ZegoCanvas(
            viewID,
            viewMode: widget.viewMode,
          ),
        ).then((_) {
          dev.log('[RtcLocalVideoView] ✅ Local preview started successfully');
        }).catchError((error) {
          dev.log('[RtcLocalVideoView] ⚠️ Error starting local preview: $error');
        });
      });

      if (mounted) {
        setState(() {
          _videoWidget = videoWidget;
        });
        dev.log('[RtcLocalVideoView] ✅ Local video canvas created successfully');
      }
    } catch (e, stackTrace) {
      dev.log('[RtcLocalVideoView] ❌ Error creating local video preview: $e', error: e, stackTrace: stackTrace);
    }
  }

  @override
  void dispose() {
    dev.log('[RtcLocalVideoView] Disposing local video preview');
    // Stop local preview
    ZegoExpressEngine.instance.stopPreview().catchError((error) {
      dev.log('[RtcLocalVideoView] Error stopping preview: $error');
      return;
    });
    // Destroy the canvas view
    if (_canvasViewID != null) {
      dev.log('[RtcLocalVideoView] Destroying canvas view: $_canvasViewID');
      ZegoExpressEngine.instance.destroyCanvasView(_canvasViewID!).catchError((error) {
        dev.log('[RtcLocalVideoView] Error destroying canvas: $error');
        return false;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _videoWidget ?? Container(
      color: Colors.black,
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}
