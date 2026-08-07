CREATE TABLE IF NOT EXISTS audio_timeline (
    job_id TEXT NOT NULL,
    sentence_id TEXT NOT NULL,
    start_sample INTEGER NOT NULL,
    end_sample INTEGER NOT NULL,
    start_ms INTEGER NOT NULL,
    end_ms INTEGER NOT NULL,
    PRIMARY KEY (job_id, sentence_id),
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS audio_outputs (
    job_id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    channels INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    encoder_version TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES build_jobs(job_id) ON DELETE CASCADE
);
