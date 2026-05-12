// Copyright 2026 Red Hat, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build !windows

package instances

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteStorageFile(t *testing.T) {
	t.Parallel()

	t.Run("writes content and leaves no temp files", func(t *testing.T) {
		t.Parallel()

		dir := t.TempDir()
		path := filepath.Join(dir, "instances.json")
		data := []byte(`[{"id":"abc"}]`)

		if err := writeStorageFile(path, data); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile: %v", err)
		}
		if string(got) != string(data) {
			t.Errorf("got %q, want %q", got, data)
		}

		// Temp file must have been cleaned up.
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatalf("ReadDir: %v", err)
		}
		if len(entries) != 1 {
			t.Errorf("expected 1 file in dir after write, got %d", len(entries))
		}
	})

	t.Run("overwrites existing file atomically", func(t *testing.T) {
		t.Parallel()

		dir := t.TempDir()
		path := filepath.Join(dir, "instances.json")

		if err := writeStorageFile(path, []byte("first")); err != nil {
			t.Fatalf("first write: %v", err)
		}
		if err := writeStorageFile(path, []byte("second")); err != nil {
			t.Fatalf("second write: %v", err)
		}

		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile: %v", err)
		}
		if string(got) != "second" {
			t.Errorf("got %q, want %q", got, "second")
		}
	})

	t.Run("fails when directory does not exist", func(t *testing.T) {
		t.Parallel()

		// os.CreateTemp fails because the parent directory is missing.
		err := writeStorageFile("/nonexistent/dir/instances.json", []byte("{}"))
		if err == nil {
			t.Error("expected error for missing directory, got nil")
		}
	})

	t.Run("fails and cleans up temp file when rename fails", func(t *testing.T) {
		t.Parallel()

		dir := t.TempDir()
		// Place a subdirectory at the target path so os.Rename fails
		// ("is a directory") while CreateTemp and Write both succeed.
		target := filepath.Join(dir, "instances.json")
		if err := os.Mkdir(target, 0755); err != nil {
			t.Fatalf("Mkdir: %v", err)
		}

		err := writeStorageFile(target, []byte("{}"))
		if err == nil {
			t.Error("expected error when rename target is a directory, got nil")
		}

		// Temp file must have been removed by the defer.
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatalf("ReadDir: %v", err)
		}
		if len(entries) != 1 {
			t.Errorf("expected 1 entry (the directory) after failed write, got %d", len(entries))
		}
	})
}
