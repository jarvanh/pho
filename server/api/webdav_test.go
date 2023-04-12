package api_test

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/fregie/img_syncer/proto"
	"github.com/fregie/img_syncer/test/static"
	"github.com/stretchr/testify/suite"
	"github.com/studio-b12/gowebdav"
	"google.golang.org/grpc"
)

const (
	webdavUrl      = "http://127.0.0.1:8000"
	webdavSrvAddr  = "http://webdav"
	webdavUser     = "fregie"
	webdavPass     = "password"
	webdavRootPath = "storage"
)

type DriveWebdavTestSuite struct {
	suite.Suite
	srv pb.ImgSyncerClient
	cli *gowebdav.Client
}

func TestDriveWebdavTestSuite(t *testing.T) {
	suite.Run(t, new(DriveWebdavTestSuite))
}

func (s *DriveWebdavTestSuite) SetupTest() {
	err := cleanWebdav()
	s.Nilf(err, "failed to clean webdav: %s", err)
	err = initWebdavDir()
	s.Nilf(err, "failed to init webdav dir: %s", err)
	grpcConn, err := grpc.Dial(grpcAddr, grpc.WithInsecure())
	s.Nil(err)
	s.srv = pb.NewImgSyncerClient(grpcConn)
	s.cli = gowebdav.NewClient(webdavUrl, webdavUser, webdavPass)
}

// TestSetDriveWebdav tests set drive webdav
func (s *DriveWebdavTestSuite) TestSetDriveWebdav() {
	ctx := context.Background()
	// test set drive webdav
	rsp1, err := s.srv.SetDriveWebdav(ctx, &pb.SetDriveWebdavRequest{
		Addr:     webdavSrvAddr,
		Username: webdavUser,
		Password: webdavPass,
	})
	s.Nilf(err, "set drive webdav failed: %v", err)
	s.True(rsp1.Success)
	// test list drive webdav dirs
	rsp2, err := s.srv.ListDriveWebdavDir(ctx, &pb.ListDriveWebdavDirRequest{})
	s.Nil(err)
	s.True(rsp2.Success)
	s.Containsf(rsp2.Dirs, webdavRootPath, "webdav root path not found")
	// test set drive webdav with root path
	rsp3, err := s.srv.SetDriveWebdav(ctx, &pb.SetDriveWebdavRequest{
		Addr:     webdavSrvAddr,
		Username: webdavUser,
		Password: webdavPass,
		Root:     webdavRootPath,
	})
	s.Nil(err)
	s.Truef(rsp3.Success, "failed to set drive webdav with root path: %s", rsp3.Message)
}

// test upload
func (s *DriveWebdavTestSuite) TestUploadDownload() {
	ctx := context.Background()
	// test set drive webdav with root path
	rsp3, err := s.srv.SetDriveWebdav(ctx, &pb.SetDriveWebdavRequest{
		Addr:     webdavSrvAddr,
		Username: webdavUser,
		Password: webdavPass,
		Root:     webdavRootPath,
	})
	s.Nil(err)
	s.True(rsp3.Success)
	// test upload
	cli, err := s.srv.Upload(ctx)
	s.Nil(err)
	// test upload file
	reader := bytes.NewReader(static.Pic1)
	err = cli.Send(&pb.UploadRequest{
		Name: "pic1.jpg",
	})
	s.Nil(err)
	buf := make([]byte, 4096)
	for {
		n, err := reader.Read(buf)
		if err != nil {
			if err == io.EOF {
				break
			} else {
				s.Nil(err)
			}
		}
		err = cli.Send(&pb.UploadRequest{
			Data: buf[:n],
		})
		s.Nil(err)
	}
	rsp4, err := cli.CloseAndRecv()
	s.Nil(err)
	s.Truef(rsp4.Success, "failed to upload file: %s", rsp4.Message)
	filePath := "/storage/2022/11/08/pic1.jpg"
	s.waitFile(filePath, 5*time.Second)
	fdata, err := s.cli.Read(filePath)
	s.Nil(err)
	s.Equal(len(fdata), len(static.Pic1))
	// s.Equalf(fdata, static.Pic1, "file data not equal")

	// test download
	data, err := s.get(ctx, pic1ShouldPath)
	s.Nil(err)
	s.Equal(len(data), len(static.Pic1))
	// s.Equalf(data, static.Pic1, "file data not equal")
}

// waitFile waits for file to be ready
func (s *DriveWebdavTestSuite) waitFile(path string, timeout time.Duration) {
	if path == "" {
		s.FailNow("path is empty")
	}
	path = filepath.ToSlash(path)
	start := time.Now()
	if path[0] != '/' {
		path = "/" + path
	}
	for {
		_, err := s.cli.Stat(path)
		if err == nil {
			break
		}
		if time.Since(start) > timeout {
			s.FailNowf("wait file timeout", "wait file %s timeout", path)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (s *DriveWebdavTestSuite) get(ctx context.Context, path string) ([]byte, error) {
	cli, err := s.srv.Get(ctx, &pb.GetRequest{
		Path: path,
	})
	if err != nil {
		return nil, err
	}
	buf := new(bytes.Buffer)
	for {
		rsp, err := cli.Recv()
		if err != nil {
			if err == io.EOF {
				break
			} else {
				return nil, err
			}
		}
		_, err = buf.Write(rsp.Data)
		if err != nil {
			return nil, err
		}
	}
	return buf.Bytes(), nil
}

func cleanWebdav() error {
	cli := gowebdav.NewClient(webdavUrl, webdavUser, webdavPass)
	dirs, err := cli.ReadDir("/")
	if err != nil {
		return err
	}
	for _, dir := range dirs {
		err = cli.RemoveAll("/" + dir.Name() + "/")
		if err != nil {
			return err
		}
	}
	return nil
}

func initWebdavDir() error {
	cli := gowebdav.NewClient(webdavUrl, webdavUser, webdavPass)
	if err := cli.Mkdir(webdavRootPath, os.ModePerm); err != nil {
		return err
	}
	return nil
}
