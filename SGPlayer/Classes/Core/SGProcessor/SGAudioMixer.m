//
//  SGAudioMixer.m
//  SGPlayer
//
//  Created by Single on 2018/11/29.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGAudioMixer.h"
#import "SGFrame+Internal.h"

@interface SGAudioMixer ()

{
    CMTime _startTime;
    CMTime _minimumTimeStamp;
    CMTime _maximumTimeStamp;
    NSArray<SGTrack *> *_tracks;
    NSArray<NSNumber *> *_weights;
    NSMutableDictionary<NSNumber *, NSMutableArray<SGAudioFrame *> *> *_frameLists;
}

@end

@implementation SGAudioMixer

- (instancetype)initWithAudioDescription:(SGAudioDescription *)audioDescription tracks:(NSArray<SGTrack *> *)tracks
{
    if (self = [super init]) {
        self->_tracks = [tracks copy];
        self->_audioDescription = [audioDescription copy];
        self->_startTime = kCMTimeNegativeInfinity;
        self->_frameLists = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc
{
    for (NSMutableArray<SGAudioFrame *> *obj in self->_frameLists.allValues) {
        for (SGAudioFrame *frame in obj) {
            [frame unlock];
        }
        [obj removeAllObjects];
    }
}

#pragma mark - Control

- (SGAudioFrame *)putFrame:(SGAudioFrame *)frame
{
    if (CMTimeCompare(frame.timeStamp, self->_startTime) < 0) {
        [frame unlock];
        return nil;
    }
    NSMutableArray<SGAudioFrame *> *queue = [self->_frameLists objectForKey:@(frame.track.index)];
    if (!queue) {
        queue = [NSMutableArray array];
        [self->_frameLists setObject:queue forKey:@(frame.track.index)];
    }
    if (queue.lastObject && CMTimeCompare(frame.timeStamp, queue.lastObject.timeStamp) <= 0) {
        [frame unlock];
        return nil;
    }
    [queue addObject:frame];
    return [self mixIfNeeded];
}

- (SGAudioFrame *)finish
{
    return nil;
}

- (SGCapacity *)capacity
{
    return [[SGCapacity alloc] init];
}

- (SGAudioFrame *)mixIfNeeded
{
    CMTime start = kCMTimePositiveInfinity;
    CMTime end = kCMTimePositiveInfinity;
    for (SGTrack *track in self->_tracks) {
        NSMutableArray<SGAudioFrame *> *frames = [self->_frameLists objectForKey:@(track.index)];
        if (frames.count < 3) {
            return nil;
        }
        CMTime currentStart = frames.firstObject.timeStamp;
        CMTime currentEnd = CMTimeAdd(frames.lastObject.timeStamp, frames.lastObject.duration);
        if (CMTimeCompare(currentStart, start) < 0) {
            start = frames.firstObject.timeStamp;
        }
        if (CMTimeCompare(currentEnd, end) < 0) {
            end = currentEnd;
        }
    }
    CMTime duration = CMTimeSubtract(end, start);
    
    int numberOfChannels = 2;
    int numberOfSamples = CMTimeGetSeconds(duration) * 44100;
    int linesize = av_get_bytes_per_sample(AV_SAMPLE_FMT_FLTP) * numberOfSamples;
    
    SGAudioFrame *ret = [[SGObjectPool sharedPool] objectWithClass:[SGAudioFrame class]];
    
    ret.core->format = self->_audioDescription.format;
    ret.core->sample_rate = self->_audioDescription.sampleRate;
    ret.core->channels = self->_audioDescription.numberOfChannels;
    ret.core->channel_layout = self->_audioDescription.channelLayout;
    ret.core->nb_samples = numberOfSamples;
    ret.core->pts                    = start.value;
    ret.core->pkt_dts                = start.value;
    ret.core->pkt_size               = 0;
    ret.core->pkt_duration           = duration.value;
    ret.core->best_effort_timestamp  = start.value;
    
    for (int i = 0; i < numberOfChannels; i++) {
        int index = 0;
        int offset = 0;
        SGAudioFrame *currentFrame = nil;
        SGAudioFrame *currentFrame2 = nil;
        float *data = av_mallocz(linesize);
        for (int j = 0; j < numberOfSamples; j++) {
            if (!currentFrame) {
                currentFrame = [[self->_frameLists objectForKey:@(0)] objectAtIndex:index];
                currentFrame2 = [[self->_frameLists objectForKey:@(1)] objectAtIndex:index];
                index += 1;
                offset = 0;
            }
            float *src = (float *)currentFrame.data[i];
            float *src2 = (float *)currentFrame2.data[i];
            data[j] = src[offset] * 0.5 + src2[offset] * 0.5;
            offset += 1;
            if (offset >= currentFrame.numberOfSamples) {
                currentFrame = nil;
                currentFrame2 = nil;
            }
        }
        AVBufferRef *buffer = av_buffer_create((uint8_t *)data, linesize, av_buffer_default_free, NULL, 0);
        ret.core->buf[i] = buffer;
        ret.core->data[i] = buffer->data;
        ret.core->linesize[i] = buffer->size;
    }
    
    SGCodecDescription *cd = [[SGCodecDescription alloc] init];
    cd.timebase = av_make_q(1, start.timescale);
    ret.codecDescription = cd;
    [ret fill];
    
    for (NSMutableArray<SGAudioFrame *> *obj in self->_frameLists.allValues) {
        for (SGAudioFrame *frame in obj) {
            [frame unlock];
        }
        [obj removeAllObjects];
    }
    
    return ret;
}

@end
